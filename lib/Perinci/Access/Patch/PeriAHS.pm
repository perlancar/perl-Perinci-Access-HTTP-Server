package Perinci::Access::Patch::PeriAHS;

use 5.010;
use strict;
use warnings;

# don't use '# VERSION' in this file, PAUSE reads it and assume
# Perinci::Access::Base's version is also this (wrong).

# xVERSION

use Perinci::Access::Base;
package Perinci::Access::Base;

sub actionmeta_srvinfo { +{
    applies_to => ['*'],
    summary    => "Get information about server",
} }

sub action_srvinfo {
    my ($self, $uri, $extra) = @_;

    my @fmt = sort map {s/::$//; $_} grep {/::$/} keys %Perinci::Formatter::;

    [200, "OK", {
        srvurl => "TODO",
        fmt    => \@fmt,
    }];
}

1;
# ABSTRACT: Add extra actions to Perinci::Access::Base

=head1 DESCRIPTION

This module injects several extra PeriAHS-related actions into
L<Perinci::Access::Base>, including: C<srvinfo>.


=head1 SEE ALSO

L<Perinci::Access::HTTP::Server>

=cut

