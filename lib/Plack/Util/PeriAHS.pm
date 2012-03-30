package Plack::Util::PeriAHS;

use 5.010;
use strict;
use warnings;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(errpage);

# VERSION

# render envelope response as an error page, either in html or json or text,
# according to $env->{"riap.request"}{fmt}. Will default to json if fmt is
# unsupported by it.

use JSON;

my $json = JSON->new->allow_nonref;

sub errpage {
    my ($env, $res) = @_;

    my $fmt = $env->{'riap.request'}{fmt} //
        $env->{"periahs.default_fmt"} // 'json';

    if ($fmt =~ /^html$/i) {
        return [
            200,
            ["Content-Type" => "text/html"],
            ["<h1>Error $res->[0]</h1>\n\n$res->[1]\n"],
        ];
    } elsif ($fmt =~ /text$/i) {
        return [
            200,
            ["Content-Type" => "text/plain"],
            ["Error $res->[0]: $res->[1]\n"],
        ];
    } else {
        return [
            200,
            ["Content-Type" => "application/json"],
            [$json->encode($res)]
        ];
    }
}

1;
#ABSTRACT: Utility routines

