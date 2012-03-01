package Plack::Middleware::PeriAHS::Access;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Request;
use Plack::Util::Accessor qw(
                                allow_logs
                                allowed_uri_schemes
                                allowed_uris
                                allowed_actions
                        );
use Plack::Util::PeriAHS qw(errpage);

# VERSION

sub prepare_app {
    my $self = shift;

    $self->{allow_logs}          //= 0;
    $self->{allowed_uri_schemes} //= ['pm'];
    #$self->{allowed_uris};
}

1;
# ABSTRACT: Deny access based on some criteria

=head1 DESCRIPTION

This middleware denies access according to some criterias in
C<$env->{"riap.request"}>. It should be put after ParseRequest.


=head1 CONFIGURATIONS

=over 4

=item * allow_logs => BOOL (default 1)

Whether to allow request for returning log messages (request key C<loglevel>
with values larger than 0). You might want to turn this off on production
servers.

=item * allowed_uri_schemes => ARRAY|REGEX (default ['pm'])

Which URI schemes are allowed. By default only local schemes are allowed. Add
'http' or 'https' if you want proxying capability.

=item * allowed_uris => ARRAY|REGEX (default ['pm'])

=item * allowed_actions => ARRAY|REGEX

Which actions are allowed.

=back

