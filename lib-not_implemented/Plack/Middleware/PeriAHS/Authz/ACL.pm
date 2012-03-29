package Plack::Middleware::PeriAHS::Authz::ACL;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Util::Accessor qw(acl acl_file autoreload_acl_file);

use Plack::Util::PeriAHS qw(errpage);

# VERSION

sub prepare_app {
    my $self = shift;
    die "Not yet implemented";
}

sub call {
    my ($self, $env) = @_;

    # continue to app
    $self->app->($env);
}

1;
# ABSTRACT: Authorize client using access-control list
__END__

=head1 SYNOPSIS

 # In app.psgi
 use Plack::Builder;

 builder {
    enable "PeriAHS::Authz::ACL";
 };


=head1 DESCRIPTION

This middleware authorizes clients using access-control list (ACL). ACL can be
specified in the 'acl' configuration or from a file ('acl_file').


=head1 CONFIGURATION

=over 4

=item * acl => ARRAY

=item * acl_file => STR

=item * autoreload_acl_file => BOOL (default 0)

=back

=cut
