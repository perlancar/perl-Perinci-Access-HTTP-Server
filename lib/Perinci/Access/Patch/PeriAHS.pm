package Perinci::Access::Patch::PeriAHS;

use 5.010;
use strict;
use warnings;

# VERSION

use Module::Patch 0.10 qw(patch_package);
use Perinci::Access::Base;

patch_package('Perinci::Access::Base', [
    {
        action => 'add',
        mod_version => ':all',
        sub_name => 'actionmeta_srvinfo',
        code => sub { +{
            applies_to => ['*'],
            summary    => "Get information about server",
        } }
    },

    {
        action => 'add',
        mod_version => ':all',
        sub_name => 'actio_srvinfo',
        code => sub {
            my ($self, $uri, $extra) = @_;

            my @fmt = sort map {s/::$//; $_} grep {/::$/}
                keys %Perinci::Formatter::;

            [200, "OK", {
                srvurl => "TODO",
                fmt    => \@fmt,
            }];
        }
    },
]);

1;
# ABSTRACT: Add action 'srvinfo' to Perinci::Access::Base

=head1 DESCRIPTION

This module injects several extra PeriAHS-related actions into
L<Perinci::Access::Base>. Currently: C<srvinfo>.


=head1 SEE ALSO

L<Perinci::Access::HTTP::Server>

=cut
