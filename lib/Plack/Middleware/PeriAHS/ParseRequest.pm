package Plack::Middleware::PeriAHS::ParseRequest;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Request;
use Plack::Util::Accessor qw(
                                accept_yaml
                                uri_pattern
                                parse_form
                                parse_path_info
                                allow_logs
                        );

use JSON;
use Perinci::Access;
use Perinci::Sub::GetArgs::Array qw(get_args_from_array);
use Plack::Util::PeriAHS qw(errpage);
use URI::Escape;

# VERSION

my $json = JSON->new->allow_nonref;

sub prepare_app {
    my $self = shift;

    $self->{accept_yaml}     //= 0;
    $self->{uri_pattern}     //= qr/(?<uri>[^?]*)/;
    $self->{parse_form}      //= 1;
    $self->{parse_path_info} //= 0;
    $self->{allow_logs}      //= 1;

    $self->{_pa} = Perinci::Access->new;
}

sub call {
    my ($self, $env) = @_;

    my $rr = $env->{"riap.request"} //= {};

    # first determine the default output format (fmt), so we can return error
    # page in that format
    my $acp = $env->{HTTP_ACCEPT} // "";
    my $fmt;
    if ($acp =~ m!/html!) {
        $fmt = "html";
    } elsif ($acp =~ m!text/!) {
        $fmt = "text";
    } else {
        $fmt = "json";
    }
    $env->{_default_fmt} = $fmt;

    # parse Riap request keys from HTTP headers (required by spec)
    for my $k0 (keys %$env) {
        next unless $k0 =~ /\AHTTP_X_RIAP_(.+?)(_J_)?\z/;
        my $v = $env->{$k0};
        my ($k, $encj) = (lc($1), $2);
        # already ensured by Plack
        #$k =~ /\A\w+\z/ or return errpage(
        #    $env, [400, "Invalid Riap request key syntax in HTTP header $k0"]);
        if ($encj) {
            eval { $v = $json->decode($v) };
            return errpage($env, [400, "Invalid JSON in HTTP header $k0"])
                if $@;
        }
        $rr->{$k} = $v;
    }

    # parse args from request body (required by spec)
    my $req = Plack::Request->new($env);
    unless (exists $rr->{args}) {
        {
            my $ct = $env->{CONTENT_TYPE};
            last unless $ct;
            last if $ct eq 'application/x-www-form-urlencoded';
            return errpage(
                $env, [400, "Unsupported request content type '$ct'"])
                unless $ct eq 'application/json' ||
                    $ct eq 'text/yaml' && $self->{accept_yaml};
            if ($ct eq 'application/json') {
                #$log->trace('Request body is JSON');
                eval { $rr->{args} = $json->decode($req->content) };
                return errpage(
                    $env, [400, "Invalid JSON in request body"]) if $@;
            #} elsif ($ct eq 'application/vnd.php.serialized') {
            #    #$log->trace('Request body is PHP serialized');
            #    request PHP::Serialization;
            #    eval { $args = PHP::Serialization::unserialize($body) };
            #    return errpage(
            #        $env, [400, "Invalid PHP serialized data in request body"])
            #        if $@;
            } elsif ($ct eq 'text/yaml') {
                require YAML::Syck;
                eval { $rr->{args} = YAML::Syck::Load($req->content) };
                return errpage(
                    $env, [400, "Invalid YAML in request body"]) if $@;
            }
        }
    }
    return errpage(
        $env, [400, "Riap request key 'args' must be hash"])
        unless !defined($rr->{args}) || ref($rr->{args}) eq 'HASH'; # sanity

    # get uri from 'uri_pattern' config
    my $pat = $self->{uri_pattern};
    my $uri = $env->{REQUEST_URI};
    my %m;
    if (ref($pat) eq 'ARRAY') {
        $uri =~ $pat->[0] or return errpage(
            $env, [404, "Request does not match uri_pattern $pat->[0]"]);
        %m = %+;
        $pat->[1]->(\%m, $env);
    } else {
        $uri =~ $pat or return errpage(
            $env, [404, "Request does not match uri_pattern $pat"]);
        %m = %+;
    }
    for (keys %m) {
        $rr->{$_} = $m{$_};
    }

    # get ss request key from form variables (optional)
    if ($self->{parse_form}) {
        my $form = $req->parameters;

        # special name 'callback' is for jsonp
        if (($rr->{fmt} // $env->{_default_fmt}) eq 'json' &&
                defined($form->{callback})) {
            return errpage(
                $env, [400, "Invalid callback syntax, please use ".
                           "a valid JS identifier"])
                unless $form->{callback} =~ /\A[A-Za-z_]\w*\z/;
            $env->{_jsonp_callback} = $form->{callback};
            delete $form->{callback};
        }

        while (my ($k, $v) = each %$form) {
            if ($k =~ /(.+):j$/) {
                $k = $1;
                #$log->trace("CGI parameter $k (json)=$v");
                eval { $v = $json->decode($v) };
                return errpage("Invalid JSON in query parameter $k: $@")
                    if $@;
            } elsif ($k =~ /(.+):y$/) {
                $k = $1;
                #$log->trace("CGI parameter $k (yaml)=$v");
                return errpage($env, [400, "YAML form variable unacceptable"])
                    unless $self->{accept_yaml};
                require YAML::Syck;
                eval { $v = YAML::Syck::Load($v) };
                return errpage(
                    $env, [400, "Invalid YAML in query parameter $k"]) if $@;
            #} elsif ($k =~ /(.+):p$/) {
            #    $k = $1;
            #    #$log->trace("PHP serialized parameter $k (php)=$v");
            #    return errpage($env, [400, "PHP serialized form variable ".
            #                              "unacceptable"])
            #        unless $self->{accept_phps};
            #    require PHP::Serialization;
            #    eval { $v = PHP::Serialization::unserialize($v) };
            #    return errpage(
            #        $env, [400, "Invalid PHP serialized data in ".
            #                       "query parameter $k: $@") if $@;
            }
            if ($k =~ /\A-riap-([\w-]+)/) {
                my $rk = lc $1; $rk =~ s/-/_/g;
                return errpage(
                    $env, [400, "Invalid Riap request key `$rk` (from form)"])
                    unless $rk =~ /\A\w+\z/;
                $rr->{$rk} //= $v;
            } else {
                $rr->{args}{$k} //= $v;
            }
        }
    }

    if ($self->{parse_path_info}) {
        {
            last unless $rr->{uri};
            my $res = $self->{_pa}->request(meta => $rr->{uri});
            last unless $res->[0] == 200;
            my $meta = $res->[2];
            last unless $meta;
            last unless $meta->{args};

            my $pi = $env->{PATH_INFO} // "";
            $pi =~ s!^/+!!;
            my @pi = map {uri_unescape($_)} split m!/+!, $pi;
            $res = get_args_from_array(array=>\@pi, meta=>$meta);
            return errpage(
                $env, [500, "Bad metadata for function $rr->{uri}: ".
                           "Can't get arguments: $res->[0] - $res->[1]"])
                unless $res->[0] == 200;
                for my $k (keys %{$res->[2]}) {
                    $rr->{args}{$k} //= $res->[2]{$k};
                }
        }
    }

    # defaults
    $rr->{v}      //= 1.1;
    $rr->{action} //= 'call';
    $rr->{fmt}    //= $env->{_default_fmt};

    # also put Riap client for later phases
    $env->{_pa} = $self->{_pa};

    # sanity: check required keys
    for (qw/uri v action/) {
        defined($rr->{$_}) or return errpage(
            $env, [500, "Required Riap request key '$_' has not been defined"]);
    }

    # normalize into URI object
    $rr->{uri} = $self->{_pa}->_normalize_uri($rr->{uri});

    # continue to app
    $self->app->($env);
}

1;
# ABSTRACT: Parse Riap request from HTTP request

=head1 SYNOPSIS

 # in your app.psgi
 use Plack::Builder;

 builder {
     enable "PeriAHS::ParseRequest",
         match_uri => m!^/api(?<uri>/[^?]*)!;
 };


=head1 DESCRIPTION

This middleware's task is to parse Riap request from HTTP request (PSGI
environment) and should normally be the first middleware put in the stack.

=head2 Parsing result

The result of parsing will be put in C<$env->{"riap.request"}> hashref.

=head2 Parsing process

B<From HTTP header and request body>. First parsing is done as per L<Riap::HTTP>
specification's requirement. All C<X-Riap-*> request headers are parsed for Riap
request key. When an unknown header is found, HTTP 400 error is returned. Then,
request body is read for C<args>. C<application/json> document type is accepted,
and also C<text/yaml> (if C<accept_yaml> configuration is enabled).

Additionally, the following are also done:

B<From URI>. Request URI is checked against B<uri_pattern> configuration. If URI
doesn't match this regex, a 404 error response is returned. It is a convenient
way to check for valid URLs as well as set Riap request keys, like:

 qr!^/api/(?<fmt>json|yaml)/!;

The default C<uri_pattern> is qr/.?/, which matches anything, but won't
parse/capture any information.

B<From form variables>. If C<parse_form> is enabled, C<args> request key will be
set (or added) from GET/POST request variables, for example:
http://host/api/foo/bar?a=1&b:j=[2] will set arguments C<a> and C<b> (":j"
suffix means value is JSON-encoded; ":y" and ":p" are also accepted if the
C<accept_yaml> and C<accept_phps> configurations are enabled). In addition,
request variables C<-ss-req-*> are also accepted for setting other SS request
keys. Unknown SS request key or encoding suffix will result in 400 error.

If request format is JSON and form variable C<callback> is defined, then it is
assumed to specify callback for JSONP instead part of C<args>. "callback(json)"
will be returned instead of just "json".

C<From URI (2)>. If C<parse_args_from_path_info> configuration is enabled, and
C<uri> SS request key contains module and subroutine name (so spec can be
retrieved), C<args> will be set (or added) from URI path info. Note that portion
matching C<uri_pattern> will be removed first. For example, when C<uri_pattern>
is qr!^/api/v1(?:/(?<module>[\w:]+)(?:/(?<sub>\w+)))?!:

 http://host/api/v1/Module::Sub/func/a1/a2/a3

will result in ['a1', 'a2', 'a3'] being fed into L<Sub::Spec::GetArgs::Array>.
An unsuccessful parsing will result in HTTP 400 error.


=head1 CONFIGURATIONS

=over 4

=item * accept_yaml => BOOL (default 0)

Whether to accept YAML-encoded data in HTTP request body and form for C<args>
Riap request key. If you only want to deal with JSON, keep this off.

=item * uri_pattern => REGEX or [REGEX, CODE] (default qr/(?<uri>[^?]*)/)

This provides an easy way to extract Riap request keys (usually C<uri>) from
HTTP request's URI. Put named captures inside the regex and it will set the
corresponding Riap request keys, e.g.:

 uri_pattern => qr!^/api(?<uri>/[^?]*)!

If regexp doesn't match, a 404 error response will be generated.

The second array form is used to customize the matching. After the match, code
will be called with reference to the named captures, in which you can delete/set
new names. Example:

 uri_pattern => [
     qr!^/ga/(?<mod>[^?/]+)(?:
            /?(?:
                (?<func>[^?/]+)?
            )
        )!x,
     sub {
         my $m=shift;
         $m->{mod} =~ s!::!/!g;
         $m->{func} //= "";
         $m->{uri} = "/$m->{mod}/$m->{func}";
         delete $m->{mod};
         delete $m->{func};
     },
 ]

This means a URI C</ga/Foo::Bar/baz> will set C<$env->{'riap.request'}{uri}> to
C</Foo/Bar/baz> and won't set C<mod> and C<func>.

=item * parse_form => BOOL (default 1)

Whether to parse C<args> keys and Riap request keys from form (GET/POST)
variable of the name C<-x-riap-*> (notice the prefix dash). If an argument is
already defined (e.g. from request body) or request key is already defined (e.g.
from C<X-Riap-*> HTTP request header), it will be skipped.

=item * parse_path_info => BOOL (default 0)

Whether to parse arguments from $env->{PATH_INFO}. Note that will require a Riap
C<meta> request to the backend, to get the specification for function arguments.
You'll also most of the time need to prepare the PATH_INFO first. Example:

 parse_path_info => 1,
 uri_pattern => [
     qr!^/ga/(?<mod>[^?/]+)(?:
            /?(?:
                (?<func>[^?/]+)?:
                (<pi>/?[^?]*)
            )
        )!x,
     sub {
         my ($m, $env) = @_;
         $m->{mod} =~ s!::!/!g;
         $m->{func} //= "";
         $m->{uri} = "/$m->{mod}/$m->{func}";
         $env->{PATH_INFO} = $m->{pi};
         delete $m->{mod};
         delete $m->{func};
         delete $m->{pi};
     },
 ]
=back


=head1 SEE ALSO

L<Perinci::Access::HTTP::Server>

=cut
