
=pod

=head1 NAME

Devscripts::Uscan::WatchFile - watchfile object for L<uscan>

=head1 DESCRIPTION

Parse watch file and creates L<Devscripts::Uscan::WatchLine> objects for
each line.

=cut

package Devscripts::Uscan::WatchFile;

use strict;
use Devscripts::Uscan::Downloader;
use Devscripts::Uscan::Output;
use Devscripts::Uscan::WatchLine;
use File::Copy qw/copy move/;
use List::Util qw/first/;
use Moo;

# Required new() parameters
has config      => ( is => 'rw', required => 1 );
has package     => ( is => 'ro', required => 1 );    # Debian package
has pkg_dir     => ( is => 'ro', required => 1 );
has pkg_version => ( is => 'ro', required => 1 );
has bare        => (
    is      => 'rw',
    lazy    => 1,
    default => sub { $_[0]->config->bare }
);
has download => (
    is      => 'rw',
    lazy    => 1,
    default => sub { $_[0]->config->download }
);
has downloader => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        Devscripts::Uscan::Downloader->new(
            {
                timeout => $_[0]->config->timeout,
                agent   => $_[0]->config->user_agent,
                passive => $_[0]->config->passive,
                destdir => $_[0]->config->destdir,
            }
        );
    },
);
has signature => (
    is       => 'rw',
    required => 1,
    lazy     => 1,
    default  => sub { $_[0]->config->signature }
);
has watchfile => ( is => 'ro', required => 1 );    # usualy debian/watch

# Internal attributes
has origcount     => ( is => 'rw' );
has origtars      => ( is => 'rw', default => sub { [] } );
has status        => ( is => 'rw', default => sub { 0 } );
has watch_version => ( is => 'rw' );
has watchlines    => ( is => 'rw', default => sub { [] } );

# Values shared between lines
has shared => (
    is      => 'rw',
    lazy    => 1,
    default => sub {
        {
            bare                        => $_[0]->bare,
            components                  => [],
            common_newversion           => undef,
            common_mangled_newversion   => undef,
            download                    => $_[0]->download,
            download_version            => undef,
            origcount                   => undef,
            origtars                    => [],
            previous_download_available => undef,
            previous_newversion         => undef,
            previous_newfile_base       => undef,
            previous_sigfile_base       => undef,
            signature                   => $_[0]->signature,
            uscanlog                    => undef,
        }
    },
);
has keyring => (
    is      => 'ro',
    default => sub { Devscripts::Uscan::Keyring->new }
);

sub BUILD {
    my ( $self, $args ) = @_;
    my $watch_version = 0;
    my $nextline;
    $dehs_tags = {};

    uscan_verbose "Process watch file at: $args->{watchfile}\n"
      . "    package = $args->{package}\n"
      . "    version = $args->{pkg_version}\n"
      . "    pkg_dir = $args->{pkg_dir}";

    $self->origcount(0);    # reset to 0 for each watch file
    unless ( open WATCH, $args->{watchfile} ) {
        uscan_warn "could not open $args->{watchfile}: $!";
        return 1;
    }

    while (<WATCH>) {
        next if /^\s*\#/;
        next if /^\s*$/;
        s/^\s*//;

      CHOMP:

        # Reassemble lines splitted using \
        chomp;
        if (s/(?<!\\)\\$//) {
            if ( eof(WATCH) ) {
                uscan_warn
                  "$args->{watchfile} ended with \\; skipping last line";
                $self->status(1);
                last;
            }
            if ( $watch_version > 3 ) {

                # drop leading \s only if version 4
                $nextline = <WATCH>;
                $nextline =~ s/^\s*//;
                $_ .= $nextline;
            }
            else {
                $_ .= <WATCH>;
            }
            goto CHOMP;
        }

        # "version" must be the first field
        if ( !$watch_version ) {

            # Looking for "version" field.
            if (/^version\s*=\s*(\d+)(\s|$)/) {    # Found
                $watch_version = $1;

                # Note that version=1 watchfiles have no "version" field so
                # authorizated values are >= 2 and <= CURRENT_WATCHFILE_VERSION
                if (   $watch_version < 2
                    or $watch_version > $main::CURRENT_WATCHFILE_VERSION )
                {
                    # "version" field found but has no authorizated value
                    uscan_warn
"$args->{watchfile} version number is unrecognised; skipping watch file";
                    last;
                }

                # Next line
                next;
            }

            # version=1 is deprecated
            else {
                uscan_warn
                  "$args->{watchfile} is an obsolete version 1 watch file;\n"
                  . "   please upgrade to a higher version\n"
                  . "   (see uscan(1) for details).";
                $watch_version = 1;
            }
        }

        # "version" is fixed, parsing lines now

        # Are there any warnings from this part to give if we're using dehs?
        dehs_output if ($dehs);

        # Handle shell \\ -> \
        s/\\\\/\\/g if $watch_version == 1;

        # Handle @PACKAGE@ @ANY_VERSION@ @ARCHIVE_EXT@ substitutions
        my $any_version = '[-_]?(\d[\-+\.:\~\da-zA-Z]*)';
        my $archive_ext = '(?i)\.(?:tar\.xz|tar\.bz2|tar\.gz|zip|tgz|tbz|txz)';
        my $signature_ext = $archive_ext . '\.(?:asc|pgp|gpg|sig|sign)';
        s/\@PACKAGE\@/$args->{package}/g;
        s/\@ANY_VERSION\@/$any_version/g;
        s/\@ARCHIVE_EXT\@/$archive_ext/g;
        s/\@SIGNATURE_EXT\@/$signature_ext/g;

        push @{ $self->watchlines }, Devscripts::Uscan::WatchLine->new(
            {
                # Shared between lines
                config     => $self->config,
                downloader => $self->downloader,
                shared     => $self->shared,
                keyring    => $self->keyring,

                # Other parameters
                line          => $_,
                pkg           => $self->package,
                pkg_dir       => $self->pkg_dir,
                pkg_version   => $self->pkg_version,
                watch_version => $watch_version,
                watchfile     => $self->watchfile,
                repack        => $self->config->repack,
                safe          => $self->config->safe,
                symlink       => $self->config->symlink,
                versionmode   => 'newer',
            }
        );
    }

    close WATCH
      or $self->status(1),
      uscan_warn "problems reading $$args->{watchfile}: $!";
    $self->watch_version($watch_version);
}

sub process_lines {
    my ($self) = shift;
    foreach ( @{ $self->watchlines } ) {

        # search newfile and newversion
        my $res = $_->process;
        $self->status($res);
    }
    return $self->{status};
}

1;