package Perinci::Access::PeriAHS;

use Perinci::Access;

use 5.010;
use strict;
use warnings;

sub new {
    my ($class, %opts) = @_;

    $opts{pa} //= Perinci::Access->new;

    bless \%opts, $class;
}

sub request {
    my ($self, $action, $uri, $extra) = @_;

    $uri = $self->{pa}->_normalize_uri($uri);
    my $sch = $uri->scheme;

    my $meth = "handle_$action";
    if ($self->can($meth)) {
        $self->$meth($uri, $extra);
    } else {
        $self->{pa}->request($action, $uri, $extra);
    }
}

sub handle_srvinfo {
    my ($self, $uri, $extra) = @_;

    my @fmt = sort map {s/::$//; $_} grep {/::$/} keys %Data::Format::Pretty::;

    [200, "OK", {
        srvurl => "TODO",
        fmt    => \@fmt,
    }];
}

1;
# ABSTRACT: Perinci::Access wrapper

=head1 DESCRIPTION

Perinci::Access::PeriAHS is used by L<Perinci::Access::HTTP::Server> (PeriAHS
for short) application. It wraps L<Perinci::Access> to intercept requests for
actions that must be implemented by PeriAHS, including: C<srvinfo>.

=cut

