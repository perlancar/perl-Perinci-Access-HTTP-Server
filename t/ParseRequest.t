#!perl

use 5.010;
use strict;
use warnings;

use JSON;
use Plack::Builder;
use Plack::Test;
use Test::More;

my $json = JSON->new->allow_nonref;

test_parse_request(
    name => "basic",
    args => {},
    posttest => sub {},
);

done_testing;

sub test_parse_request {
    my %args = @_;
    my $riap_req;

    my $app = builder {
        #enable "PeriAHS::ParseRequest", %{$args{args}};
        sub {
            my $env = shift;
            $riap_req = $env->{"riap.request"};
            return [
                200,
                ['Content-Type' => 'plain/text'],
                [$json->encode($riap_req)]
            ];
        };
    };

    test_psgi app => $app, client => sub {
        my $cb = shift;

        my $res = $cb->(HTTP::Request->new(GET => 'http://localhost/'));
        subtest $args{name} => sub {
            is($res->code, $args{status} // 200, "status");

            if ($args{posttest}) {
                $args{posttest}->();
            }

            done_testing;
        };
    };
}
