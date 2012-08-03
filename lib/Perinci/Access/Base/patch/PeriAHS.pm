package Perinci::Access::Base::patch::PeriAHS;

use 5.010;
use strict;
use warnings;

use Module::Patch 0.10 qw();
use base qw(Module::Patch);

# VERSION

sub patch_data {
    return {
        v => 3,
        patches => [
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
                sub_name => 'action_srvinfo',
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
        ],
    };
}

1;
# ABSTRACT: Patch for Perinci::Access::Base

=head1 DESCRIPTION

This patch adds several extra PeriAHS-related actions into
L<Perinci::Access::Base>. Currently: C<srvinfo>.


=head1 SEE ALSO

L<Perinci::Access::HTTP::Server>

=cut
