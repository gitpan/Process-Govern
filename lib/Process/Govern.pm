package Process::Govern;

use 5.010001;
use strict;
use warnings;

our $VERSION = '0.07'; # VERSION

use Exporter qw(import);
our @EXPORT_OK = qw(govern_process);

use Time::HiRes qw(sleep);

sub new {
    my ($class) = @_;
    bless {}, $class;
}

sub _suspend {
    my $self = shift;
    my $h = $self->{h};
    say "D:Suspending program ..." if $self->{debug};
    kill STOP => $_->{PID} for @{ $h->{KIDS} };
    $self->{suspended} = 1;
}

sub _resume {
    my $self = shift;
    my $h = $self->{h};
    say "D:Resuming program ..." if $self->{debug};
    kill CONT => $_->{PID} for @{ $h->{KIDS} };
    $self->{suspended} = 0;
}

sub _kill {
    my $self = shift;
    my $h = $self->{h};
    $self->_resume if $self->{suspended};
    say "D:Killing program ..." if $self->{debug};
    $h->kill_kill;
}

sub govern_process {
    my $self;
    if (ref $_[0]) {
        $self = shift;
    } else {
        $self = __PACKAGE__->new;
    }

    my %args = @_;
    $self->{args} = \%args;

    my $debug = $ENV{DEBUG};
    $self->{debug} = $debug;

    my $cmd = $args{command};
    defined($cmd) or die "Please specify command\n";

    my $name = $args{name};
    if (!defined($name)) {
        $name = ref($cmd) eq 'ARRAY' ? $cmd->[0] : ref($cmd) ? 'prog' : $cmd;
        $name =~ s!.*/!!; $name =~ s/\W+/_/g;
        length($name) or $name = "prog";
    }
    defined($name) or die "Please specify name\n";
    $name =~ /\A\w+\z/ or die "Invalid name, please use letters/numbers only\n";
    $self->{name} = $name;

    if ($args{single_instance}) {
        defined($args{pid_dir}) or die "Please specify pid_dir\n";
        require Proc::PID::File;
        if (Proc::PID::File->running(
            dir=>$args{pid_dir}, name=>$name, verify=>1)) {
            if ($args{on_multiple_instance} &&
                    $args{on_multiple_instance} eq 'exit') {
                exit 202;
            } else {
                warn "Program $name already running\n";
                exit 202;
            }
        }
    }

    my $lw     = $args{load_watch} // 0;
    my $lwfreq = $args{load_check_every} // 10;
    my $lwhigh = $args{load_high_limit}  // 1.25;
    my $lwlow  = $args{load_low_limit}   // 0.25;

    ###

    my $out = sub {
        print $_[0];
    };

    my $err;
    my $fwr;
    if ($args{log_stderr}) {
        require File::Write::Rotate;
        my %fwrargs = %{$args{log_stderr}};
        $fwrargs{dir}    //= "/var/log";
        $fwrargs{prefix}   = $name;
        $fwr = File::Write::Rotate->new(%fwrargs);
        $err = sub {
            print STDERR $_[0];
            # XXX prefix with timestamp, how long script starts,
            $_[0] =~ s/^/STDERR: /mg;
            $fwr->write($_[0]);
        };
    } else {
        $err = sub {
            print STDERR $_[0];
        };
    }

    my $start_time = time();
    require IPC::Run;
    say "D:Starting program $name ..." if $debug;
    my $to = IPC::Run::timeout(1);
    #$self->{to} = $to;
    my $h  = IPC::Run::start($cmd, \*STDIN, $out, $err, $to)
        or die "Can't start program: $?\n";
    $self->{h} = $h;

    local $SIG{INT} = sub {
        say "D:Received INT signal" if $debug;
        $self->_kill;
        exit 1;
    };

    local $SIG{TERM} = sub {
        say "D:Received TERM signal" if $debug;
        $self->_kill;
        exit 1;
    };

    my $res;
    my $lastlw_time;

  MAIN_LOOP:
    while (1) {
        #say "D:main loop" if $debug;
        if (!$self->{suspended}) {
            # re-set timer, it might be reset by suspend/resume?
            $to->start(1);

            unless ($h->pumpable) {
                $h->finish;
                $res = $h->result;
                last MAIN_LOOP;
            }

            eval { $h->pump };
            my $everr = $@;
            die $everr if $everr && $everr !~ /^IPC::Run: timeout/;
        } else {
            sleep 1;
        }
        my $now = time();

        if (defined $args{timeout}) {
            if ($now - $start_time >= $args{timeout}) {
                $err->("Timeout ($args{timeout}s), killing child ...\n");
                $self->_kill;
                # mark with a special exit code that it's a timeout
                $res = 201;
                last MAIN_LOOP;
            }
        }

        if ($lw && (!$lastlw_time || $lastlw_time <= ($now-$lwfreq))) {
            say "D:Checking load" if $debug;
            if (!$self->{suspended}) {
                my $is_high;
                if (ref($lwhigh) eq 'CODE') {
                    $is_high = $lwhigh->($h);
                } else {
                    require Sys::LoadAvg;
                    my @load = Sys::LoadAvg::loadavg();
                    $is_high = $load[0] >= $lwhigh;
                }
                if ($is_high) {
                    say "D:Load is too high" if $debug;
                    $self->_suspend;
                }
            } else {
                my $is_low;
                if (ref($lwlow) eq 'CODE') {
                    $is_low = $lwlow->($h);
                } else {
                    require Sys::LoadAvg;
                    my @load = Sys::LoadAvg::loadavg();
                    $is_low = $load[0] <= $lwlow;
                }
                if ($is_low) {
                    say "D:Load is low" if $debug;
                    $self->_resume;
                }
            }
            $lastlw_time = $now;
        }

    }
    exit $res;
}

1;
# ABSTRACT: Run child process and govern its various aspects


__END__
=pod

=head1 NAME

Process::Govern - Run child process and govern its various aspects

=head1 VERSION

version 0.07

=head1 SYNOPSIS

To use via command-line (in most cases):

 % govproc \
       --timeout 3600 \
       --log-stderr-dir        /var/log/myapp/ \
       --log-stderr-size       16M \
       --log-stderr-histories  12 \
   /path/to/myapp

To use directly as Perl module:

 use Process::Govern qw(govern_process);
 govern_process(
     name       => 'myapp',
     command    => '/path/to/myapp',
     timeout    => 3600,
     stderr_log => {
         dir       => '/var/log/myapp',
         size      => '16M',
         histories => 12,
     },
 );

=head1 DESCRIPTION

Process::Govern is a child process manager. It is meant to be a convenient
bundle (a single parent/monitoring process) for functionalities commonly needed
when managing a child process. It comes with a command-line interface,
L<govproc>.

Background story: I first created this module to record STDERR output of scripts
that I run from cron. The scripts already log debugging information using
L<Log::Any> to an autorotated log file (using L<Log::Dispatch::FileRotate>, via
L<Log::Any::Adapter::Log4perl>, via L<Log::Any::App>). However, when the scripts
warn/die, or when the programs that the scripts execute emit messages to STDERR,
they do not get recorded. Thus, every script is then run through B<govproc>.
From there, B<govproc> naturally gets additional features like timeout,
preventing running multiple instances, and so on.

Currently the following governing functionalities are available:

=over

=item * logging of STDERR output to an autorotated file

=item * execution time limit

=item * preventing multiple instances from running simultaneously

=item * load watch

=back

In the future the following features are also planned or contemplated:

=over

=item * CPU time limit

=item * memory limit

With an option to autorestart if process' memory size grow out of limit.

=item * other resource usage limit

=item * fork/start multiple processes

=item * autorestart on die/failure

=item * set (CPU) nice level

=item * set I/O nice level (scheduling priority/class)

=item * limit STDIN input, STDOUT/STDERR output?

=item * trap/handle some signals for the child process?

=item * set UID/GID?

=item * provide daemon functionality?

=item * provide network server functionality?

Inspiration: djb's B<tcpserver>.

=item * set/clean environment variables

=back

=for Pod::Coverage ^(new)$

=head1 EXIT CODES

Below is the list of exit codes that Process::Govern uses:

=over

=item * 201

Timeout.

=item * 202

Another instance is already running (when C<single_instance> option is true).

=back

=head1 FUNCTIONS

=head2 govern_process(%args)

Run child process and govern its various aspects. It basically uses L<IPC::Run>
and a loop to check various conditions during the lifetime of the child process.
Known arguments (required argument is marked with C<*>):

=over

=item * command* => STR | ARRAYREF | CODE

Program to run. Passed to IPC::Run's C<start()>.

=item * name => STRING

Should match regex C</\A\w+\z/>. Used in several ways, e.g. passed as C<prefix>
in L<File::Write::Rotate>'s constructor as well as used as name of PID file.

If not given, will be taken from command.

=item * timeout => INT

Apply execution time limit, in seconds. After this time is reached, process (and
all its descendants) are first sent the TERM signal. If after 30 seconds pass
some processes still survive, they are sent the KILL signal.

The killing is implemented using L<IPC::Run>'s C<kill_kill()>.

Upon timeout, exit code is set to 201.

=item * log_stderr => HASH

Specify logging for STDERR. Logging will be done using L<File::Write::Rotate>.
Known hash keys: C<dir> (STR, defaults to /var/log, directory, preferably
absolute, where the log file(s) will reside, should already exist and be
writable, will be passed to File::Write::Rotate's constructor), C<size> (INT,
also passed to File::Write::Rotate's constructor), C<histories> (INT, also
passed to File::Write::Rotate's constructor), C<period> (STR, also passed to
File::Write::Rotate's constructor).

=item * single_instance => BOOL

If set to true, will prevent running multiple instances simultaneously.
Implemented using L<Proc::PID::File>. You will also normally have to set
C<pid_dir>, unless your script runs as root, in which case you can use the
default C</var/log>.

=item * pid_dir => STR (default: /var/log)

Directory to put PID file in. Relevant if C<single> is set to true.

=item * on_multiple_instance => STR

Can be set to 'exit' to silently exit when there is already a running instance.
Otherwise, will print an error message 'Program <NAME> already running'.

=item * load_watch => BOOL (default: 0)

If set to 1, enable load watching. Program will be suspended when system load is
too high and resumed if system load returns to a lower limit.

=item * load_high_limit => INT|CODE (default: 1.25)

Limit above which program should be suspended, if load watching is enabled. If
integer, will be compared against L<Sys::LoadAvg>'s LOADAVG_1MIN value.
Alternatively, you can provide a custom routine here, code should return true if
load is considered too high.

=item * load_low_limit => INT|CODE (default: 0.25)

Limit below which program should resume, if load watching is enabled. If
integer, will be compared against L<Sys::LoadAvg>'s LOADAVG_1MIN value.
Alternatively, you can provide a custom routine here, code should return true if
load is considered low.

=item * load_check_every => INT (default: 10)

Frequency of load checking, in seconds.

=back

=head1 FAQ

=head2 Why use Process::Govern?

The main feature this module offers is convenience: it creates a single parent
process to monitor child process. This fact is more pronounced when you need to
monitor lots of child processes. If you use, on the other hand, use separate
parent/monitoring process for timeout and then a separate one for CPU watching,
and so on, there will potentially be a lot more processes running on the system.

=head1 CAVEATS

Not yet tested on Win32.

=head1 SEE ALSO

Process::Govern attempts (or will attempt, some day) to provide the
functionality (or some of the functionality) of the builtins/modules/programs
listed below:

=over

=item * Starting/autorestarting

djb's B<supervise>, http://cr.yp.to/daemontools/supervise.html

=item * Pausing under high system load

B<loadwatch>. This program also has the ability to run N copies of program and
interactively control stopping/resuming via Unix socket.

cPanel also includes a program called B<cpuwatch>.

=item * Preventing multiple instances of program running simultaneously

L<Proc::PID::File>, L<Sys::RunAlone>

=item * Execution time limit

alarm() (but alarm() cannot be used to timeout external programs started by
system()/backtick).

L<Sys::RunUntil>

=item * Logging

djb's B<multilog>, http://cr.yp.to/daemontools/multilog.html

=back

Although not really related, L<Perinci::Sub::Wrapper>. This module also bundles
functionalities like timeout, retries, argument validation, etc into a single
function wrapper.

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

