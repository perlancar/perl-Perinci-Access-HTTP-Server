package Plack::Util::Periuk;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(errpage allowed);

# VERSION

# XXX use requested format, e.g. JSON
sub errpage {
    my ($msg, $code) = @_;
    $msg .= "\n" unless $msg =~ /\n\z/;
    $code //= 400;
    $msg = "$code - $msg";
    $log->tracef("Sending errpage %s - %s", $code, $msg);
    [$code,
     ["Content-Type" => "text/plain", "Content-Length" => length($msg)],
     [$msg]];
}

sub allowed {
    my ($value, $pred) = @_;
    if (ref($pred) eq 'ARRAY') {
        return $value ~~ @$pred;
    } else {
        return $value =~ /$pred/;
    }
}

1;
