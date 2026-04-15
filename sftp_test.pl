#!/usr/bin/perl

# send backlog of missed files like this:
# find archive -iname "libraryname*" -exec ./sftp_test.pl --config config/libraryname.conf --file {} \;
# replace libraryname with the name of the config and matching filenames

use strict;
use warnings;
use Getopt::Long;
use File::Spec;
use lib 'lib';  # Ensure the script can find the SFTP module
use SFTP qw(do_sftp_upload);
use Logging qw(init_logging logmsg);
use Utils qw(read_config);

# Read command line arguments
my $file_path;
my $config_file;

GetOptions("file=s" => \$file_path, "config_file=s" => \$config_file);

# Check if file path is provided
if (!$file_path) {
    die "Usage: $0 --file <path_to_file>\n";
}

# Read configuration file
my $conf = read_config($config_file);

# Initialize logging
init_logging($conf->{logfile}, 1);

# Resolve the file path to an absolute path
my $abs_file_path = File::Spec->rel2abs($file_path);

# Check if the file exists
if (!-e $abs_file_path) {
    logmsg("ERROR", "File does not exist: $abs_file_path");
    die "File does not exist: $abs_file_path\n";
}

# Get SFTP details from configuration
my $host = $conf->{ftphost};
my $user = $conf->{ftplogin};
my $pass = $conf->{ftppass};
my $remote_dir = $conf->{remote_directory};

# Perform SFTP upload
my $sftp_error = do_sftp_upload($host, $user, $pass, $remote_dir, $abs_file_path);

if ($sftp_error) {
    logmsg("ERROR", "SFTP ERROR: $sftp_error");
    die "SFTP ERROR: $sftp_error\n";
} else {
    logmsg("INFO", "SFTP success: Uploaded $abs_file_path to $remote_dir on $host");
    print "SFTP success: Uploaded $abs_file_path to $remote_dir on $host\n";
}