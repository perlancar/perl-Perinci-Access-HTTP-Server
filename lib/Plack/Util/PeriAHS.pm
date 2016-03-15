package Plack::Util::PeriAHS;

# DATE
# VERSION

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(errpage);

use JSON::MaybeXS;

my $json = JSON::MaybeXS->new->allow_nonref;

sub errpage {
    my ($env, $rres) = @_;

    my $fmt = $env->{'riap.request'}{fmt} //
        $env->{"periahs.default_fmt"} // 'json';
    my $pres;

    if ($fmt =~ /^html$/i) {
        $pres = [
            200,
            ["Content-Type" => "text/html"],
            ["<h1>Error $rres->[0]</h1>\n\n$rres->[1]\n"],
        ];
    } elsif ($fmt =~ /text$/i) {
        $pres = [
            200,
            ["Content-Type" => "text/plain"],
            ["Error $rres->[0]: ".$rres->[1].($rres->[1] =~ /\n$/ ? "":"\n")],
        ];
    } else {
        $pres = [
            200,
            ["Content-Type" => "application/json"],
            [$json->encode($rres)]
        ];
    }

    $log->tracef("Returning error page: %s", $pres);
    $pres;
}

1;
#ABSTRACT: Utility routines

=head1 FUNCTIONS

=head2 errpage($env, $resp)

Render enveloped response $resp (as specified in L<Rinci::function>) as an error
page PSGI response, either in HTML/JSON/plaintext (according to C<<
$env->{"riap.request"}{fmt} >>). Will default to JSON if C<fmt> is unsupported.

$env is PSGI environment.

=cut
