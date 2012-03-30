package Plack::Middleware::PeriAHS::CheckAccess;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Util::Accessor qw(
                                allow_log
                                allow_uri_scheme
                                deny_uri_scheme
                                allow_uri
                                deny_uri
                                allow_action
                                deny_action
                        );
use Plack::Util::PeriAHS qw(errpage);
use SHARYANTO::Array::Util qw(match_array_or_regex);
use URI;

# VERSION

sub prepare_app {
    my $self = shift;

    $self->{allow_log}         //= 0;
    $self->{allow_uri_scheme}  //= ['pm'];
}

sub call {
    $log->tracef("=> PeriAHS::ParseRequest middleware");

    my ($self, $env) = @_;

    my $rreq = $env->{"riap.request"};
    my $uri  = $rreq->{uri};

    if (!$self->{allow_log}) {
        return errpage($env, [403, "Setting loglevel is forbidden"])
            if $rreq->{loglevel};
    }

    if ($self->{allow_uri_scheme}) {
        my $sch = $uri->scheme;
        return errpage($env, [403, "Riap URI scheme not allowed (not in list)"])
            unless match_array_or_regex($sch, $self->{allow_uri_scheme});
    }
    if ($self->{deny_uri_scheme}) {
        my $sch = $uri->scheme;
        return errpage($env, [403, "Riap URI scheme not allowed (deny list)"])
            if match_array_or_regex($sch, $self->{deny_uri_scheme});
    }

    if ($self->{allow_uri}) {
        return errpage($env, [403, "Riap URI not allowed (not in list)"])
            unless match_array_or_regex("$uri", $self->{allow_uri});
    }
    if ($self->{deny_uri}) {
        return errpage($env, [403, "Riap URI not allowed (deny list)"])
            if match_array_or_regex("$uri", $self->{deny_uri});
    }

    if ($self->{allow_action}) {
        return errpage($env, [403, "Riap action not allowed (not in list)"])
            unless match_array_or_regex($rreq->{action}, $self->{allow_action});
    }
    if ($self->{deny_action}) {
        return errpage($env, [403, "Riap action '$rreq->{action}' not allowed ".
                                  "(deny list)"])
            if match_array_or_regex($rreq->{action}, $self->{deny_action});
    }

    # continue to app
    $self->app->($env);
}

1;
# ABSTRACT: Deny access based on some criteria

=head1 DESCRIPTION

This middleware denies access according to some criterias in
C<$env->{"riap.request"}>. It should be put after ParseRequest.

For a more sophisticated access control, try the PeriAHS::ACL middleware.


=head1 CONFIGURATIONS

=over 4

=item * allow_log => BOOL (default 1)

Whether to allow request for returning log messages (request key C<loglevel>
with values larger than 0). You might want to turn this off on production
servers.

=item * allow_uri_scheme => ARRAY|REGEX (default ['pm'])

Which URI schemes are allowed. By default only local schemes are allowed. Add
'http' or 'https' if you want proxying capability.

=item * deny_uri_scheme => ARRAY|REGEX

Which URI schemes are forbidden.

=item * allow_uri => ARRAY|REGEX (default ['pm'])

Allowed URIs. Note that URIs are normalized with scheme C<pm> if unschemed.
Example:

=item * deny_uri => ARRAY|REGEX (default ['pm'])

Forbidden URIs.

=item * allow_action => ARRAY|REGEX

Which actions are allowed.

=item * deny_action => ARRAY|REGEX

Which actions are forbidden.

=back
