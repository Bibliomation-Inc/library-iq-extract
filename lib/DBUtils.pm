package DBUtils;

use strict;
use warnings;
use DBI;
use Exporter 'import';
use Logging qw(logmsg);
use Utils qw(dedupe_array);
use XML::Simple;

our @EXPORT_OK = qw(get_dbh chunked_ids fetch_data_by_ids get_db_config create_history_table get_org_units get_last_run_time set_last_run_time drop_schema);

# ----------------------------------------------------------
# get_dbh - Return a connected DBI handle
# ----------------------------------------------------------
sub get_dbh {
    my ($db_config) = @_;
    my $dsn = "dbi:Pg:dbname=$db_config->{db};host=$db_config->{host};port=$db_config->{port}";
    my $dbh = DBI->connect($dsn, $db_config->{user}, $db_config->{pass},
        { RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1 }
    ) or do {
        my $error_msg = "DBI connect error: $DBI::errstr";
        logmsg("ERROR", $error_msg);
        die "$error_msg\n";
    };
    logmsg("INFO", "Successfully connected to the database: $db_config->{db} at $db_config->{host}:$db_config->{port}");
    my $masked_db_config = { %$db_config, pass => '****' };
    logmsg("DEBUG", "DB Config:\n\t" . join("\n\t", map { "$_ => $masked_db_config->{$_}" } keys %$masked_db_config));
    return $dbh;
}

# ----------------------------------------------------------
# get_db_config - Get database configuration from Evergreen config file
# ----------------------------------------------------------
sub get_db_config {
    my ($evergreen_config_file) = @_;
    my $xml = XML::Simple->new;
    my $data = $xml->XMLin($evergreen_config_file);
    my $db_settings = $data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database};
    return {
        db   => $db_settings->{db},
        host => $db_settings->{host},
        port => $db_settings->{port},
        user => $db_settings->{user},
        pass => $db_settings->{pw},
    };
}

# ----------------------------------------------------------
# chunked_ids - Return array of arrays, each containing ID chunks
# ----------------------------------------------------------
sub chunked_ids {
    my ($dbh, $sql, $date_filter, $chunk_size) = @_;

    my @all_ids;
    my $sth = $dbh->prepare($sql);
    if (defined $date_filter) {
        # Determine the number of placeholders in the SQL statement
        my $num_placeholders = () = $sql =~ /\?/g;
        if ($num_placeholders == 2) {
            $sth->execute($date_filter, $date_filter);
        } elsif ($num_placeholders == 1) {
            $sth->execute($date_filter);
        } else {
            $sth->execute();
        }
    } else {
        $sth->execute();
    }

    while (my ($id) = $sth->fetchrow_array) {
        push @all_ids, $id;
    }
    $sth->finish;

    # Now break @all_ids into smaller arrays of size $chunk_size
    my @chunks;
    while (@all_ids) {
        my @slice = splice(@all_ids, 0, $chunk_size);
        push @chunks, \@slice;
    }
    return @chunks;
}

# ----------------------------------------------------------
# fetch_data_by_ids - fetch actual data given an array of IDs
# ----------------------------------------------------------
sub fetch_data_by_ids {
    my ($dbh, $id_chunk, $query, @extra_params) = @_;
    
    my $occurrences = () = $query =~ /:id_list/g;   # how many times :id_list appears
    my $ids_in_chunk = scalar @$id_chunk;

    my $placeholders = join(',', ('?') x $ids_in_chunk);
    my $sql = $query;
    $sql =~ s/:id_list/$placeholders/g;

    # Replicate IDs per occurrence
    my @bind_ids;
    if ($occurrences > 1) {
        for (1 .. $occurrences) {
            push @bind_ids, @$id_chunk;
        }
    } else {
        @bind_ids = @$id_chunk;
    }

    my @bind_params = (@bind_ids, @extra_params);

    # Placeholder math / diagnostics (only log if mismatch)
    my $total_placeholders_in_sql = () = $sql =~ /\?/g;
    my $expected_id_placeholders  = $ids_in_chunk * ($occurrences || 1);
    my $expected_extra            = $total_placeholders_in_sql - $expected_id_placeholders;
    my $extra_params_supplied     = scalar @extra_params;

    my $mismatch_extra = ($expected_extra != $extra_params_supplied);
    my $mismatch_total = ($total_placeholders_in_sql != ($expected_id_placeholders + $extra_params_supplied));

    if ($mismatch_extra || $mismatch_total) {
        logmsg("DEBUG",
            "fetch_data_by_ids mismatch: chunk_ids=$ids_in_chunk occurrences=$occurrences "
            . "expected_id_placeholders=$expected_id_placeholders total_placeholders_in_sql=$total_placeholders_in_sql "
            . "expected_extra_placeholders=$expected_extra extra_params_supplied=$extra_params_supplied "
            . "computed_total_bind_params=" . scalar(@bind_params)
            . ($mismatch_total ? " (TOTAL PLACEHOLDER COUNT MISMATCH)" : "")
        );
    }

    my $sth = $dbh->prepare($sql);
    $sth->execute(@bind_params);

    my @rows;
    while (my $row = $sth->fetchrow_arrayref) {
        push @rows, [@$row];
    }
    $sth->finish;
    return @rows;
}

# ----------------------------------------------------------
# create_history_table - Create the libraryiq.history table if it doesn't exist
# ----------------------------------------------------------
sub create_history_table {
    my ($dbh, $log_file, $debug) = @_;
    my $sql = q{
        CREATE SCHEMA IF NOT EXISTS libraryiq;
        CREATE TABLE IF NOT EXISTS libraryiq.history (
            id serial PRIMARY KEY,
            key TEXT NOT NULL,
            last_run TIMESTAMP WITH TIME ZONE DEFAULT '1000-01-01'::TIMESTAMPTZ
        )
    };
    $dbh->do($sql);
    logmsg("INFO", "Ensured libraryiq.history table exists");
}

# ----------------------------------------------------------
# drop_schema - Drop the libraryiq schema
# ----------------------------------------------------------
sub drop_schema {
    my ($dbh) = @_;
    my $sql = q{
        DROP SCHEMA IF EXISTS libraryiq CASCADE
    };
    $dbh->do($sql);
}

# ----------------------------------------------------------
# get_org_units - Get organization units based on library shortnames
# ----------------------------------------------------------
sub get_org_units {
    my ($dbh, $librarynames, $include_descendants) = @_;
    my @ret = ();

    # spaces don't belong here
    $librarynames =~ s/\s//g;

    my @sp = split( /,/, $librarynames );

    @sp = map { "'" . lc($_) . "'" } @sp;
    my $libs = join(',', @sp);

    my $query = "
    select id
    from
    actor.org_unit
    where lower(shortname) in ($libs)
    order by 1";
    logmsg("DEBUG", "Executing query: $query");
    my $sth = $dbh->prepare($query);
    $sth->execute();
    while (my @row = $sth->fetchrow_array) {
        push( @ret, $row[0] );
        if ($include_descendants) {
            my @des = @{ get_org_descendants($dbh, $row[0]) };
            push( @ret, @des );
        }
    }

    if (!@ret) {
        my $error_msg = "No organization units found for library shortnames: $librarynames";
        logmsg("ERROR", $error_msg);
        die "$error_msg\n";
    }

    return dedupe_array(\@ret);
}

# ----------------------------------------------------------
# get_org_descendants - Get organization unit descendants
# ----------------------------------------------------------
sub get_org_descendants {
    my ($dbh, $thisOrg) = @_;
    my $query = "select id from actor.org_unit_descendants($thisOrg)";
    my @ret = ();
    logmsg("DEBUG", "Executing query: $query");

    my $sth = $dbh->prepare($query);
    $sth->execute();
    while (my $row = $sth->fetchrow_array) {
        push(@ret, $row);
    }

    return \@ret;
}

# ----------------------------------------------------------
# get_last_run_time - Get the last run time from the database
# ----------------------------------------------------------
sub get_last_run_time {
    my ($dbh, $org_units) = @_;
    my $key = join(',', @$org_units);
    my $sql = "SELECT last_run FROM libraryiq.history WHERE key = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute($key);
    if (my ($ts) = $sth->fetchrow_array) {
        $sth->finish;
        return $ts || '1900-01-01'; # Return '1900-01-01' if no timestamp found
    } else {
        $sth->finish;
        logmsg("INFO", "No existing entry. Using old date -> 1900-01-01");
        return '1900-01-01';
    }
}

# ----------------------------------------------------------
# set_last_run_time - Set the last run time in the database
# ----------------------------------------------------------
sub set_last_run_time {
    my ($dbh, $org_units) = @_;
    my $key = join(',', @$org_units);
    my $sql_upd = q{
      UPDATE libraryiq.history SET last_run=now() WHERE key=?
    };
    my $sth_upd = $dbh->prepare($sql_upd);
    my $rows = $sth_upd->execute($key);
    if ($rows == 0) {
        # Might need an INSERT if row does not exist
        my $sql_ins = q{
          INSERT INTO libraryiq.history(key, last_run) VALUES(?, now())
        };
        $dbh->do($sql_ins, undef, $key);
    }
    logmsg("INFO", "Updated last_run time for org units: $key");
}

1;