#!/usr/bin/perl

# =============================================================================
# LibraryIQ Extract Script
# Author: Ian Skelskey
# Copyright (C) 2024 Bibliomation Inc.
#
# This script extracts data from Evergreen ILS and sends it to LibraryIQ.
# For use in cases when your security policy does not allow direct access to
# the database. The script can be run on a server with access to the database
# and the extracted data can be sent to LibraryIQ via SFTP.
#
# This program is free software; you can redistribute it and/or modify it 
# under the terms of the GNU General Public License as published by the 
# Free Software Foundation; either version 2 of the License, or (at your 
# option) any later version.
# =============================================================================

use strict;
use warnings;
use Time::HiRes qw(gettimeofday tv_interval);

use lib 'lib';  # or the path to your local modules
use DBUtils qw(get_dbh get_db_config create_history_table get_org_units get_last_run_time set_last_run_time chunked_ids fetch_data_by_ids drop_schema);
use SFTP qw(do_sftp_upload);
use Email qw(send_email);
use Logging qw(init_logging logmsg logheader);
use Queries qw(
    get_bib_ids_sql
    get_bib_detail_sql
    get_item_ids_sql
    get_item_detail_sql
    get_circ_ids_sql
    get_circ_detail_sql
    get_patron_ids_sql
    get_patron_detail_sql
    get_hold_ids_sql
    get_hold_detail_sql
    get_inhouse_ids_sql
    get_inhouse_detail_sql
    get_ordered_items_ids_sql
    get_ordered_items_detail_sql
    get_requested_holds_ids_sql
    get_requested_holds_detail_sql
    get_fulfilled_holds_ids_sql
    get_fulfilled_holds_detail_sql
    get_unfilled_holds_ids_sql
    get_unfilled_holds_detail_sql
    );

use Utils qw(read_config read_cmd_args check_config check_cmd_args write_data_to_file create_tar_gz);

# Capture the start time
my $start_time = [gettimeofday];

###########################
# 1) Parse Config & CLI
###########################

logheader("Reading Configuration and CLI Arguments");

# Read command line arguments
my ($config_file, $evergreen_config_file, $debug, $full, $no_email, $no_sftp, $drop_history, $no_update_history) = read_cmd_args();

# Read and check configuration file
my $conf = read_config($config_file);

# Initialize logging
my $log_file = $conf->{logfile};
init_logging($log_file, $debug);

# Check config and CLI values
check_config($conf);
check_cmd_args($config_file);
logmsg("SUCCESS", "Config file and CLI values are valid");

###########################
# 2) DB Connection
###########################
my $db_config = get_db_config($evergreen_config_file);
my $dbh = get_dbh($db_config);
logmsg("SUCCESS", "Connected to DB");

###########################
# 3) Ensure History Table Exists
###########################

# Drop and recreate the libraryiq schema if --drop-history is specified
if ($drop_history) {
    drop_schema($dbh);
    logmsg("SUCCESS", "Dropped existing LibraryIQ schema.");
}

create_history_table($dbh, $log_file, $debug);

###########################
# 4) Get Organization Units
###########################
my $librarynames = $conf->{librarynames};
logmsg("INFO", "Library names: $librarynames");
my $include_descendants = exists $conf->{include_org_descendants};
my $org_units = get_org_units($dbh, $librarynames, $include_descendants);
my $pgLibs = join(',', @$org_units);
logmsg("INFO", "Organization units: $pgLibs");

###########################
# 5) Figure out last run vs full
###########################
my $last_run_time = get_last_run_time($dbh, $org_units);

# Calculate the overlap period
my $diff_overlap_days = $conf->{diff_overlap_days} || 0;
my $overlap_date = DateTime->now->subtract(days => $diff_overlap_days)->ymd;

my $run_date_filter = $full ? undef : $overlap_date;
logheader("Run mode: " . ($full ? "FULL" : "INCREMENTAL from $overlap_date"));


###########################
# 6) Process Data Types
###########################

sub get_data {
    my ($data_type, $id_sql, $detail_sql, @extra_params) = @_;

    # Get chunks of IDs based on the provided SQL query and date filter
    my @chunks = chunked_ids($dbh, $id_sql, $run_date_filter, $conf->{chunksize});
    logmsg("INFO", "Found ".(scalar @chunks)." ID chunks for $data_type");

    my @data;
    # Process each chunk of IDs
    foreach my $chunk (@chunks) {
        # Fetch data for the current chunk of IDs
        my @rows = fetch_data_by_ids($dbh, $chunk, $detail_sql, @extra_params);
        push @data, @rows;
    }

    return @data;
}

# Define a very old date for full runs
my $very_old_date = '1900-01-01';

my $prefix = $conf->{filenameprefix};
my $dt = DateTime->now( time_zone => "local" );
my $fdate = $dt->ymd;
my $suffix = $full ? 'full' : 'diff';

# Process BIBs
my @bibs = get_data(
    'bibs',
    get_bib_ids_sql($full, $pgLibs),
    get_bib_detail_sql(),
    $full ? ($very_old_date, $very_old_date) : ($run_date_filter, $run_date_filter)
);
my $bib_out_file = write_data_to_file("${prefix}_bibs_${fdate}_${suffix}", \@bibs, [qw/id isbn upc mat_type pubdate publisher title author/], $conf->{tempdir});

# Process Items
my @items = get_data(
    'items',
    get_item_ids_sql($full, $pgLibs),
    get_item_detail_sql(),
    $full ? ($very_old_date, $very_old_date) : ($run_date_filter, $run_date_filter)
);
my $item_out_file = write_data_to_file("${prefix}_items_${fdate}_${suffix}", \@items, [qw/itemid barcode isbn upc bibid collection_code mattype branch_location owning_location call_number shelf_location create_date status last_checkout last_checkin due_date ytd_circ_count circ_count last_status_date last_update_date last_inventory_date/], $conf->{tempdir});

# Process Circs
my @circs = get_data(
    'circs',
    get_circ_ids_sql($full, $pgLibs),
    get_circ_detail_sql(),
    $full ? ($very_old_date) : ($run_date_filter)
);
my $circ_out_file = write_data_to_file("${prefix}_circs_${fdate}_${suffix}", \@circs, [qw/itemid barcode bibid checkout_date checkout_branch patron_id due_date checkin_time/], $conf->{tempdir});

# Process Patrons
my @patrons = get_data(
    'patrons',
    get_patron_ids_sql($full, $pgLibs),
    get_patron_detail_sql(),
    $full ? ($very_old_date, $very_old_date) : ($run_date_filter, $run_date_filter)
);
my $patron_out_file = write_data_to_file("${prefix}_patrons_${fdate}_${suffix}", \@patrons, [qw/id expire_date shortname create_date patroncode status ytd_circ_count prev_year_circ_count total_circ_count last_activity last_checkout street1 street2 city state post_code/], $conf->{tempdir});

# Process Holds
my @holds = get_data(
    'holds',
    get_hold_ids_sql($full, $pgLibs),
    get_hold_detail_sql(),
    $full ? ($very_old_date) : ($run_date_filter)
);
my $hold_out_file = write_data_to_file("${prefix}_holds_${fdate}_${suffix}", \@holds, [qw/bibrecordid pickup_lib shortname hold_count/], $conf->{tempdir});

# Process Inhouse
my @inhouse = get_data(
    'inhouse',
    get_inhouse_ids_sql($full, $pgLibs),
    get_inhouse_detail_sql(),
    $full ? ($very_old_date) : ($run_date_filter)
);
my $inhouse_out_file = write_data_to_file("${prefix}_inhouse_${fdate}_${suffix}", \@inhouse, [qw/itemid barcode bibid checkout_date checkout_branch/], $conf->{tempdir});

# Process Ordered Items (no date filtering; always returns all results for matching orgs)
my @ordereditems = get_data(
    'ordereditems',
    get_ordered_items_ids_sql($full, $pgLibs),
    get_ordered_items_detail_sql()
);
my $ordered_out_file = write_data_to_file("${prefix}_ordereditems_${fdate}_${suffix}", \@ordereditems, 
    [qw/bibliographicrecordid numberofcopies reportdate assignedbranchabbr/], $conf->{tempdir});

# Process Requested Holds
my @requestedholds = get_data(
    'requestedholds',
    get_requested_holds_ids_sql($full, $pgLibs),
    get_requested_holds_detail_sql()
);
my $requested_holds_out_file = write_data_to_file(
    "${prefix}_requestedholds_${fdate}_${suffix}",
    \@requestedholds,
    [qw/bibliographicrecordid holdrequestid transactionid pickuplocation requesteddate reportdate/],
    $conf->{tempdir}
);

# Process Fulfilled Holds
my @fulfilledholds = get_data(
    'fulfilledholds',
    get_fulfilled_holds_ids_sql($full, $pgLibs),
    get_fulfilled_holds_detail_sql()
);
my $fulfilled_holds_out_file = write_data_to_file(
    "${prefix}_fulfilledholds_${fdate}_${suffix}",
    \@fulfilledholds,
    [qw/bibliographicrecordid holdrequestid transactionid pickuplocation fulfilleddate reportdate/],
    $conf->{tempdir}
);

# Process Unfilled Holds (fixed last 2 days window)
my @unfilledholds = get_data(
    'unfilledholds',
    get_unfilled_holds_ids_sql($pgLibs),
    get_unfilled_holds_detail_sql()
);
my $unfilled_holds_out_file = write_data_to_file(
    "${prefix}_unfilledholds_${fdate}_${suffix}",
    \@unfilledholds,
    [qw/bibliographicrecordid holdrequestid requesteddate requestedpickuplocation/],
    $conf->{tempdir}
);

###########################
# 7) Create tar.gz archive
###########################
my @output_files = ($bib_out_file, $item_out_file, $circ_out_file, $patron_out_file, $hold_out_file, $inhouse_out_file, $ordered_out_file, $requested_holds_out_file, $fulfilled_holds_out_file, $unfilled_holds_out_file);
my $archive_file;
if ($conf->{compressoutput}) {
    $archive_file = create_tar_gz(\@output_files, $conf->{archive}, $conf->{filenameprefix}, $full);
} else {
    # Move TSV files to the archive directory and update their paths
    my @archived_files;
    foreach my $file (@output_files) {
        my $filename = (split('/', $file))[-1];
        my $destination = $conf->{archive} . '/' . $filename;
        rename($file, $destination) or warn "Could not move $file to $destination: $!";
        logmsg("INFO", "Moved $file to archive directory: $destination");
        push @archived_files, $destination;
    }
    $archive_file = \@archived_files;  # Use updated paths for SFTP upload
}

###########################
# 8) SFTP upload & Email
###########################
my $sftp_error;
unless ($no_sftp) {
    $sftp_error = do_sftp_upload(
        $conf->{ftphost}, 
        $conf->{ftplogin}, 
        $conf->{ftppass}, 
        $conf->{remote_directory}, 
        $archive_file
    );

    if ($sftp_error) {
        logmsg("ERROR", "SFTP upload failed: $sftp_error");
    } else {
        logmsg("SUCCESS", "SFTP upload successful");
    }
}

# Calculate the elapsed time
my $elapsed_time = tv_interval($start_time);
my $hours = int($elapsed_time / 3600);
my $minutes = int(($elapsed_time % 3600) / 60);
my $seconds = $elapsed_time % 60;
my $formatted_time = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);

unless ($no_email) {
    my $subject = "LibraryIQ Extract - " . ($full ? "FULL" : "INCREMENTAL");
    my $alwaysemail = $conf->{alwaysemail};

    # Generate the HTML body with record counts
    my $html_body = <<"END_HTML";
<html>
<head>
    <title>LibraryIQ Extract Report</title>
</head>
<body>
    <p>LibraryIQ Extract has completed.</p>
    <p><strong>Details:</strong></p>
    <ul>
        <li>Start Time: @{[scalar localtime($start_time->[0])]}</li>
        <li>End Time: @{[scalar localtime]}</li>
        <li>Elapsed Time: $formatted_time</li>
        <li>Mode: @{[$full ? "FULL" : "INCREMENTAL"]}</li>
        <li>Chunk Size: $conf->{chunksize}</li>
        <li>SFTP Error: @{[$sftp_error ? $sftp_error : "None"]}</li>
    </ul>
    <p><strong>Record Counts:</strong></p>
    <ul>
        <li>BIBs: @{[scalar @bibs]}</li>
        <li>Items: @{[scalar @items]}</li>
        <li>Circs: @{[scalar @circs]}</li>
        <li>Patrons: @{[scalar @patrons]}</li>
        <li>Holds: @{[scalar @holds]}</li>
        <li>Inhouse: @{[scalar @inhouse]}</li>
        <li>OrderedItems: @{[scalar @ordereditems]}</li>
        <li>RequestedHolds: @{[scalar @requestedholds]}</li>
        <li>FulfilledHolds: @{[scalar @fulfilledholds]}</li>
        <li>UnfilledHolds: @{[scalar @unfilledholds]}</li>
    </ul>
    <p>Thank you,<br>LibraryIQ Extract Script</p>
</body>
</html>
END_HTML

    if ($sftp_error) {
        # Send failure email if there was an SFTP error
        my @error_recipients = split /,/, $conf->{erroremaillist};
        push @error_recipients, $alwaysemail;
        my $error_subject = "LibraryIQ Extract - FAILURE";
        my $error_body = <<"END_HTML";
<html>
<head>
    <title>LibraryIQ Extract Failure</title>
</head>
<body>
    <p>LibraryIQ Extract encountered an error during SFTP upload: $sftp_error</p>
    <p><strong>Details:</strong></p>
    <ul>
        <li>Start Time: @{[scalar localtime($start_time->[0])]}</li>
        <li>End Time: @{[scalar localtime]}</li>
        <li>Elapsed Time: $formatted_time</li>
        <li>Mode: @{[$full ? "FULL" : "INCREMENTAL"]}</li>
        <li>Chunk Size: $conf->{chunksize}</li>
        <li>SFTP Error: $sftp_error</li>
    </ul>
    <p>Thank you,<br>LibraryIQ Extract Script</p>
</body>
</html>
END_HTML

        my $email_error = send_email(
            $conf->{fromemail},
            \@error_recipients,
            $error_subject,
            $error_body
        );

        if ($email_error) {
            logmsg("INFO", "Error email sent to: ".join(',', @error_recipients)
                ." from: ".$conf->{fromemail}
                ." with subject: $error_subject"
                ." and body: $error_body");
        } else {
            logmsg("ERROR", "Failed to send error email. Check the configuration file. Continuing...");
        }
    } else {
        # Send success email
        my @success_recipients = split /,/, $conf->{successemaillist};
        push @success_recipients, $alwaysemail;
        my $email_success = send_email(
            $conf->{fromemail},
            \@success_recipients,
            $subject,
            $html_body
        );

        if ($email_success) {
            logmsg("INFO", "Success email sent to: ".join(',', @success_recipients));
            logmsg("DEBUG", "Email details - From: ".$conf->{fromemail}
                .", Subject: $subject"
                .", Body: $html_body");
        } else {
            logmsg("ERROR", "Failed to send success email. Check the configuration file. Continuing...");
        }
    }
}

###########################
# 9) Update last run time & cleanup
###########################
unless ($no_update_history || $sftp_error) {
    set_last_run_time($dbh, $org_units);
}

logheader("Finished Library IQ Extract\nin $formatted_time\nChunk size: $conf->{chunksize}\nSFTP Error: " . ($sftp_error ? $sftp_error : "None"));

###########################
# 10) Cleanup Old Files
###########################
sub cleanup_old_files {
    my ($directory, $prefix) = @_;
    opendir(my $dh, $directory) or die "Cannot open directory $directory: $!";
    my @files = grep { /^${prefix}_.*\.(tsv|tar\.gz)$/ && -f "$directory/$_" } readdir($dh);
    closedir($dh);

    # Group files by type (diff or full) and date
    my %files_by_type_and_date;
    foreach my $file (@files) {
        if ($file =~ /_(\d{4}-\d{2}-\d{2})_(full|diff)\./) {
            my ($date, $type) = ($1, $2);
            push @{$files_by_type_and_date{$type}{$date}}, $file;
        }
    }

    # Determine the latest date for each type
    my %latest_date_by_type;
    foreach my $type (keys %files_by_type_and_date) {
        my @dates = sort keys %{$files_by_type_and_date{$type}};
        $latest_date_by_type{$type} = $dates[-1] if @dates;
    }

    # Delete files not associated with the latest date for each type
    foreach my $type (keys %files_by_type_and_date) {
        foreach my $date (keys %{$files_by_type_and_date{$type}}) {
            if ($date ne $latest_date_by_type{$type}) {  # Only keep files from the latest date
                foreach my $old_file (@{$files_by_type_and_date{$type}{$date}}) {
                    unlink("$directory/$old_file") or warn "Could not delete $directory/$old_file: $!";
                    logmsg("INFO", "Deleted old $type file from $date: $old_file");
                }
            }
        }
    }
}

sub cleanup_temp_directory {
    my ($directory) = @_;
    opendir(my $dh, $directory) or die "Cannot open directory $directory: $!";
    my @files = grep { -f "$directory/$_" } readdir($dh);
    closedir($dh);

    foreach my $file (@files) {
        unlink("$directory/$file") or warn "Could not delete $directory/$file: $!";
        logmsg("INFO", "Deleted temp file: $file");
    }
}

# Perform cleanup
if ($conf->{cleanup}) {
    # Clean up the archive directory
    cleanup_old_files($conf->{archive}, $conf->{filenameprefix});
}

# Ensure the temp directory is empty
cleanup_temp_directory($conf->{tempdir});

exit 0;