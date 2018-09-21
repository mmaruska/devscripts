package Devscripts::Uscan::FindFiles;

use strict;
use filetest 'access';
use Cwd qw/cwd/;
use Exporter 'import';
use Devscripts::Uscan::Output;
use Devscripts::Versort;
use Dpkg::Changelog::Parse qw(changelog_parse);
use File::Basename;

our @EXPORT = ('find_watch_files');

sub find_watch_files {
    my ($config) = @_;
    my $opwd = cwd();

    # when --watchfile is used
    if ( defined $config->watchfile ) {
        uscan_verbose "Option --watchfile=$config->{watchfile} used\n";
        my ($config) = (@_);

        # no directory traversing then, and things are very simple
        if ( defined $config->package ) {

            # no need to even look for a changelog!
            return (
                [
                    '.', $config->package, $config->uversion,
                    $config->watchfile
                ]
            );
        }
        else {
            # Check for debian/changelog file
            until ( -r 'debian/changelog' ) {
                chdir '..' or uscan_die "can't chdir ..: $!\n";
                if ( cwd() eq '/' ) {
                    uscan_die "Are you in the source code tree?\n"
                      . "   Cannot find readable debian/changelog anywhere!\n";
                }
            }

            # Figure out package info we need
            my $changelog = eval { changelog_parse(); };
            if ($@) {
                uscan_die "Problems parsing debian/changelog: $@\n";
            }

            my ( $package, $debversion, $uversion );
            $package = $changelog->{Source};
            uscan_die
              "Problem determining the package name from debian/changelog\n"
              unless defined $package;
            $debversion = $changelog->{Version};
            uscan_die "Problem determining the version from debian/changelog\n"
              unless defined $debversion;

            # Check the directory is properly named for safety
            if ( $config->check_dirname_level == 2
                or ( $config->check_dirname_level == 1 and cwd() ne $opwd ) )
            {
                my $good_dirname;
                my $re = $config->check_dirname_regex;
                $re =~ s/PACKAGE/\Q$package\E/g;
                if ( $re =~ m%/% ) {
                    $good_dirname = ( cwd() =~ m%^$re$% );
                }
                else {
                    $good_dirname = ( basename( cwd() ) =~ m%^$re$% );
                }
                uscan_die "The directory name "
                  . basename( cwd() )
                  . " doesn't match the requirement of\n"
                  . "   --check_dirname_level=$config->{check_dirname_level} --check-dirname-regex=$re .\n"
                  . "   Set --check-dirname-level=0 to disable this sanity check feature.\n"
                  unless defined $good_dirname;
            }

            # Get current upstream version number
            if ( defined $config->uversion ) {
                $uversion = $config->uversion;
            }
            else {
                $uversion = $debversion;
                $uversion =~ s/-[^-]+$//;    # revision
                $uversion =~ s/^\d+://;      # epoch
            }

            return ( [ cwd(), $package, $uversion, $config->watchfile ] );
        }
    }

    # when --watchfile is not used, scan watch files
    push @ARGV, '.' if !@ARGV;
    {
        local $, = ',';
        uscan_verbose "Scan watch files in @ARGV\n";
    }

    # Run find to find the directories.  We will handle filenames with spaces
    # correctly, which makes this code a little messier than it would be
    # otherwise.
    my @dirs;
    open FIND, '-|', 'find', @ARGV, qw(-follow -type d -name debian -print)
      or uscan_die "Couldn't exec find: $!\n";

    while (<FIND>) {
        chomp;
        push @dirs, $_;
        uscan_debug "Found $_\n";
    }
    close FIND;

    uscan_die "No debian directories found\n" unless @dirs;

    my @debdirs = ();

    my $origdir = cwd;
    for my $dir (@dirs) {
        $dir =~ s%/debian$%%;

        unless ( chdir $origdir ) {
            uscan_warn "Couldn't chdir back to $origdir, skipping: $!\n";
            next;
        }
        unless ( chdir $dir ) {
            uscan_warn "Couldn't chdir $dir, skipping: $!\n";
            next;
        }

        uscan_verbose "Check debian/watch and debian/changelog in $dir\n";

        # Check for debian/watch file
        if ( -r 'debian/watch' ) {
            unless ( -r 'debian/changelog' ) {
                uscan_warn
                  "Problems reading debian/changelog in $dir, skipping\n";
                next;
            }

            # Figure out package info we need
            my $changelog = eval { changelog_parse(); };
            if ($@) {
                uscan_warn
                  "Problems parse debian/changelog in $dir, skipping\n";
                next;
            }

            my ( $package, $debversion, $uversion );
            $package = $changelog->{Source};
            unless ( defined $package ) {
                uscan_warn
"Problem determining the package name from debian/changelog\n";
                next;
            }
            $debversion = $changelog->{Version};
            unless ( defined $debversion ) {
                uscan_warn
                  "Problem determining the version from debian/changelog\n";
                next;
            }
            uscan_verbose
"package=\"$package\" version=\"$debversion\" (as seen in debian/changelog)\n";

            # Check the directory is properly named for safety
            if ( $config->check_dirname_level == 2
                or ( $config->check_dirname_level == 1 and cwd() ne $opwd ) )
            {
                my $good_dirname;
                my $re = $config->check_dirname_regex;
                $re =~ s/PACKAGE/\Q$package\E/g;
                if ( $re =~ m%/% ) {
                    $good_dirname = ( cwd() =~ m%^$re$% );
                }
                else {
                    $good_dirname = ( basename( cwd() ) =~ m%^$re$% );
                }
                unless ( defined $good_dirname ) {
                    uscan_die "The directory name "
                      . basename( cwd() )
                      . " doesn't match the requirement of\n"
                      . "   --check_dirname_level=$config->{check_dirname_level} --check-dirname-regex=$re .\n"
                      . "   Set --check-dirname-level=0 to disable this sanity check feature.\n";
                    next;
                }
            }

            # Get upstream version number
            $uversion = $debversion;
            $uversion =~ s/-[^-]+$//;    # revision
            $uversion =~ s/^\d+://;      # epoch

            uscan_verbose
"package=\"$package\" version=\"$uversion\" (no epoch/revision)\n";
            push @debdirs, [ $debversion, $dir, $package, $uversion ];
        }
    }

    uscan_warn "No watch file found\n" unless @debdirs;

    # Was there a --upstream-version option?
    if ( defined $config->uversion ) {
        if ( @debdirs == 1 ) {
            $debdirs[0][3] = $config->uversion;
        }
        else {
            uscan_warn
"ignoring --upstream-version as more than one debian/watch file found\n";
        }
    }

    # Now sort the list of directories, so that we process the most recent
    # directories first, as determined by the package version numbers
    @debdirs = Devscripts::Versort::deb_versort(@debdirs);

    # Now process the watch files in order.  If a directory d has
    # subdirectories d/sd1/debian and d/sd2/debian, which each contain watch
    # files corresponding to the same package, then we only process the watch
    # file in the package with the latest version number.
    my %donepkgs;
    my @results;
    for my $debdir (@debdirs) {
        shift @$debdir;    # don't need the Debian version number any longer
        my $dir       = $$debdir[0];
        my $parentdir = dirname($dir);
        my $package   = $$debdir[1];
        my $version   = $$debdir[2];

        if ( exists $donepkgs{$parentdir}{$package} ) {
            uscan_warn
"Skipping $dir/debian/watch\n   as this package has already been found\n";
            next;
        }

        unless ( chdir $origdir ) {
            uscan_warn "Couldn't chdir back to $origdir, skipping: $!\n";
            next;
        }
        unless ( chdir $dir ) {
            uscan_warn "Couldn't chdir $dir, skipping: $!\n";
            next;
        }

        uscan_verbose
"$dir/debian/changelog sets package=\"$package\" version=\"$version\"\n";
        push @results, [ $dir, $package, $version, "debian/watch", cwd ];
    }
    unless ( chdir $origdir ) {
        uscan_die "Couldn't chdir back to $origdir! $!\n";
    }
    return @results;
}

1;
