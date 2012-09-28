#!/usr/bin/perl -w
# Copyright © 2006-2009 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or
# implied warranty.
#
# Speaks the Denon AVR/AVC control protocol language.
#
# I have a Lantronix UDS-10 serial-to-ethernet adapter plugged into the
# serial port on my Denon AVR-2805 tuner.  This script talks to that host
# and lets me switch inputs, volume, etc. remotely.
#
# E.g.:
#
#    tuner power=on input=tv volume='-40.5 dB'
#
# Created: 19-Nov-2006.

require 5;
use diagnostics;
use strict;

use POSIX;
use Socket;
use IO::Handle;

my $progname = $0; $progname =~ s@.*/@@g;
my $version = q{ $Revision: 1.6 $ }; $version =~ s/^[^0-9]+([0-9.]+).*$/$1/;

my $verbose = 0;
my $debug   = 0;

my $device = "/dev/ttyUSB0";    # serial port
#my $device = "tuner:10001";    # or hostname and tcp port
my $speed = B9600;
my $http_proxy = undef;

# The manual says that after sending a command, "the response should be
# sent within 200 milliseconds of receiving the command."
#
# What it doesn't say is that after reading the response for one command,
# you have to wait nearly a FULL SECOND before sending a second command,
# and if you don't, BOTH commands are ignored!
#
my $command_delay = 0.95;


sub open_serial() {

  if ($debug) {
    open (SERIAL, "+</dev/null");
    print STDERR "$progname: opened /dev/null (debug mode)\n"
      if ($verbose);
    return;
  }

  if ($device =~ m@^([^:/]+):([^:/.]+)$@) {   # host:port, not local serial

    my $host = $1;
    my $port = $2;

    my $host2 = $host;
    my $port2 = $port;
    if ($http_proxy) {
      $device = $http_proxy if $http_proxy;
      ($host2,$port2) = split(/:/, $device);
      $port2 = 80 unless $port2;
    }

    my ($remote, $iaddr, $paddr, $proto, $line);
    $remote = $host2;
    if ($port2 =~ /\D/) { $port2 = getservbyname($port2, 'tcp') }
    error ("unrecognised port: $port2") unless ($port2);
    $iaddr   = inet_aton($remote);
    error ("host not found: $remote") unless ($iaddr);
    $paddr = sockaddr_in($port2, $iaddr);
    $proto = getprotobyname('tcp');

    if (!socket(SERIAL, PF_INET, SOCK_STREAM, $proto)) {
      error ("socket: $!");
    }
    print STDERR "$progname: connecting to $device\n" if ($verbose);
    if (!connect(SERIAL, $paddr)) {
      error ("connect: $device: $!");
    }

    print STDERR "$progname: connected to $device\n" if ($verbose);

    # Set unbuffered (is this necessary?)
    #
    select((select(SERIAL), $| = 1)[0]);

    # Set nonblocking
    #
    my $flags = fcntl(SERIAL, F_GETFL, 0) ||
      error ("can't get flags for the socket: $!");
    $flags = fcntl(SERIAL, F_SETFL, $flags | O_NONBLOCK) ||
      error ("can't set flags for the socket: $!");

    print STDERR "$progname: initialized connection\n" if ($verbose);

  } else {                               # local serial port

    #open (SERIAL, "+<$device") || error ("$device: $!")";
    sysopen (SERIAL, $device, O_RDWR|O_NONBLOCK|O_NOCTTY|O_EXCL) ||
      error ("$device: $!");

    print STDERR "$progname: opened $device\n" if ($verbose);

    # Set unbuffered (is this necessary?)
    #
    select((select(SERIAL), $| = 1)[0]);

    # Set line speed
    #
    my $t =  POSIX::Termios->new;
    $t->getattr(fileno(SERIAL));
    $t->setispeed($speed);
    $t->setospeed($speed);
    $t->setattr(fileno(SERIAL), TCSANOW);

    print STDERR "$progname: initialized $device\n" if ($verbose);
  }

  # Flush any bits on the stream already.
  #
  my $buf = "";
  while (sysread(SERIAL, $buf, 1024)) {
    if ($verbose) {
      $buf =~ s/\r\n/\n/g;
      $buf =~ s/\r/\n/g;
      $buf =~ s/\n$//s;
      foreach (split (/\n/, $buf)) {
        $_ = sprintf "%-8s (flush)", $_;
        print STDERR "$progname: <<< $_\n";
      }
    }
  }
}

sub close_serial() {
  if ($debug) {
    print STDERR "$progname: close (debug)\n";
    return;
  }
  close SERIAL || error ("$device: $!");
  print STDERR "$progname: closed $device\n" if ($verbose);
}


# Like sleep but is guaranteed to work on fractions of a second.
sub my_sleep($) {
  my ($secs) = @_;
  print STDERR "$progname:    sleep $secs\n" if ($verbose > 2);
  select(undef, undef, undef, $secs);
}


# write a one-line command.
#
sub raw_cmd($) {
  my ($cmd) = @_;
  $cmd =~ s/[\r\n]+$//gs;

  (print SERIAL "$cmd\r\n") || error ("$device: $!");
  print STDERR "$progname:  >>> $cmd\n" if ($verbose > 1);
}

# read a response from a command.
# This is assumed to be a single line.
#
sub raw_reply() {

  return "" if $debug;

  my $wait = $command_delay;   # wait no longer than this long for a reply.

  my $result = "";
  while (1) {
    my $rin='';
    my $rout;
    vec($rin,fileno(SERIAL),1) = 1;

    my $nfound = select($rout=$rin, undef, undef, $wait);
    $wait = 0;
    last unless $nfound;
    my $buf = '';
    while (sysread (SERIAL, $buf, 1024)) {
      $result .= $buf;
    }
  }

  # convert linebreaks.
  #
  $result =~ s/\r\n/\n/g;
  $result =~ s/\r/\n/g;

  # print what we got...
  #
  if ($verbose > 1) {
    if ($result =~ m/^\s*$/s) {
      print STDERR "$progname:  <<< no reply!\n";
      } else {
        foreach (split (/\n/, $result)) {
          print STDERR "$progname:  <<< $_\n";
        }
    }
  }

  return $result;
}


sub denon_raw_command($$$) {
  my ($cmd, $rawcmd, $queryp) = @_;

  raw_cmd ($rawcmd);
  my $result = raw_reply ();

  if ($queryp) {
    if ($result =~ m/^\s*$/s) {
      print STDOUT "$progname: $cmd = FAIL!\n";
    }

    foreach my $line (split (/\n/, $result)) {
      my $cmd2;
      ($cmd2, $line) = ($line =~ m/^(..)(.*)/s);
      if ($cmd2 eq 'MV') {
        my $n = $line;
        $n .= "0" if ($n =~ /^..$/);
        if ($n =~ m/^(\d+)$/m) {        
          $line = sprintf ("%.1f dB", (800 - $n) / -10.0);
        } 
        
      }

      if    ($cmd2 eq 'PW') { $cmd2 = 'POWER';  }
      elsif ($cmd2 eq 'SI') { $cmd2 = 'INPUT';  }
      elsif ($cmd2 eq 'MU') { $cmd2 = 'MUTE';   }
      elsif ($cmd2 eq 'MV') { $cmd2 = 'VOLUME'; }

      print STDOUT "$progname: $cmd2 = $line\n";
    }
  }
}


# Converts a dB value to the integral range Denon uses.
#
sub db_to_raw($) {
  my ($arg) = @_;
  my $db = $arg;
  $db =~ s/^\+//;
  $db += 0.0;
  error ("dB must be in range -80.0 to -1.0, not \"$arg\"")
    unless ($db <= -1.0 && $db >= -80.0);

  #   +1.0 dB  810
  #   +0.5 dB  805
  #    0.0 dB  800
  #   -0.5 dB  795
  #   -1.0 dB  790
  #   -1.5 dB  785
  #   -2.0 dB  780
  #       ...
  #  -79.5 dB  005
  #  -80.0 dB  000
  #       ---  990

  return (800 - int ($db * -10));
}


sub current_volume() {
  raw_cmd ('MV?');
  my $result = raw_reply ();
  if ($result =~ m/^MV(\d+)$/m) {
    my $n = $1;
    $n .= '0' if ($n =~ m/^..$/);
    return $n;
  } else {
    print STDOUT "$progname: FAIL getting current volume!\n";
    exit 1;
  }
}


sub denon_command($) {
  my ($cmd) = @_;

  $cmd = uc($cmd);
  my $arg = undef;

  if ($cmd =~ m/^([^=]+)\s*=\s*(.*)$/si) {
    ($cmd, $arg) = ($1, $2);
    $arg = undef if ($arg eq '');
  }

  $arg = '?' if (defined($arg) && $arg eq 'QUERY');

  my $rawcmd;
  if ($cmd =~ m/^INPUT$/si) {
    $rawcmd = "SI";

    # aliases
    if (!defined($arg))                { $arg = '?';         }
    elsif ($arg =~ m/^(DBS|SAT)$/si)   { $arg = 'DBS/SAT';   }
    elsif ($arg =~ m/^VAUX|AUX$/si)    { $arg = 'V.AUX';     }
    elsif ($arg =~ m/^CDR|TAPE-?1$/si) { $arg = 'CDR/TAPE1'; }
    elsif ($arg =~ m/^MD|TAPE-?2$/si)  { $arg = 'MD/TAPE2';  }
    elsif ($arg =~ m/^(VCR)(\d)$/si)   { $arg = "$1-$2";     }

    error ("unknown input source: $arg")
      unless ($arg =~ m@^(\?|PHONO|CD|TUNER|DVD|VDP|TV|DBS/SAT|VCR-[123]|
                        V\.AUX|CDR/TAPE1|MD/TAPE2)$@xsi);
    $rawcmd .= $arg;

  } elsif ($cmd =~ m/^MUTE$/si) {
    if (! defined($arg))       { $arg = 'ON';   }
    elsif ($arg =~ m/^ON$/si)  { $arg = 'ON';   }
    elsif ($arg =~ m/^OFF$/si) { $arg = 'OFF';  }
    elsif ($arg =~ m/^\?$/si)  { $arg = '?';    }
    else { error ("mute: on or off, not $arg"); }
    $rawcmd = "MU$arg";

  } elsif ($cmd =~ m/^UNMUTE$/si) {
    error ("unmute: no args allowed: $arg") if defined($arg);
    $rawcmd = "MUOFF";

  } elsif ($cmd =~ m/^POWER$/si) {
    if (! defined($arg))       { $arg = '?';       }
    elsif ($arg =~ m/^\?$/si)  { $arg = '?';       }
    elsif ($arg =~ m/^ON$/si)  { $arg = 'ON';      }
    elsif ($arg =~ m/^OFF$/si) { $arg = 'STANDBY'; }
    else { error ("power: on or off, not $arg");   }
    $rawcmd = "PW$arg";

  } elsif ($cmd =~ m/^VOL(UME)?$/si) {
    my $change;
    if (! defined($arg))              { $arg = '?';      }
    elsif ($arg =~ m/^\?$/si)         { $arg = '?';      }
    elsif ($arg =~ m/^UP\s*([\d.]+)?$/si)   { $arg = 'UP';   $change =  $1; }
    elsif ($arg =~ m/^DOWN\s*([\d.]+)?$/si) { $arg = 'DOWN'; $change = -$1; }
    elsif ($arg =~ m/^([-+]?\d+\.?\d*)\s*(dB)?$/si) {
      $arg = sprintf("%03d", db_to_raw ($1));
      $arg =~ s/0$//;
    }
    else { error ("volume: UP, DOWN, or 'NN dB', not $arg"); }

    if (defined ($change)) {
      $arg = current_volume();
      $arg += $change * 10;
      $arg = sprintf("%03d", $arg);
      $arg =~ s/0$//;
      my_sleep ($command_delay * 1.5);  # WTF!  COME ON!
    }

    $rawcmd = "MV$arg";
  } else {
    usage();
    exit 1;
  }

  my $queryp = 1 if ($arg eq '?' || $verbose);
  denon_raw_command ($cmd, $rawcmd, $queryp);
}


sub error($) {
  my ($err) = @_;
  print STDERR "$progname: $err\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] CMD=ARG ...\n" .
    "\n" .
    "    Commands:  Args:\n" .
    "\n" .
    "      INPUT    QUERY PHONO CD TUNER DVD VDP TV DBS\n" .
    "               VCR-1 VCR-2 VCR-3 AUX TAPE-1 TAPE-2\n" .
    "      MUTE     QUERY ON OFF\n" .
    "      POWER    QUERY ON OFF\n" .
    "      VOLUME   QUERY UP DOWN  \"NN dB\"" .
    "               UPn DOWNn (where 'n' is a dB value)\n" .
    "\n";
  exit 1;
}

sub main() {
  my @cmds;
  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/) { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^--?debug$/) { $debug++; }
    elsif (m/^-[^\d]/) { usage; }
    else { push @cmds, $_; }
  }

  usage unless ($#cmds >= 0);

  open_serial ();

  my $count = 0;
  foreach (@cmds) {
    my_sleep ($command_delay) if ($count > 0);
    denon_command ($_);
    $count++;
  }

  close_serial ();
}

main();
exit 0;

