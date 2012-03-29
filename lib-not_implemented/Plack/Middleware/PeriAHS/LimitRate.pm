package Plack::Middleware::PeriAHS::LimitRate;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
#use Plack::Util::Accessor qw();

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
# ABSTRACT: Limit access rate
__END__

=head1 SYNOPSIS

 # In app.psgi
 use Plack::Builder;

 builder {
    enable "PeriAHS::LimitRate";
 };


=head1 DESCRIPTION

This middleware limits access rate. Not yet implemented.


=head1 CONFIGURATION

=over 4

=back

=cut
