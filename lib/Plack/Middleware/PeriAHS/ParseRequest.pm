package Plack::Middleware::PeriAHS::ParseRequest;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use parent qw(Plack::Middleware);
use Plack::Request;
use Plack::Util::Accessor qw(
                                match_uri
                                parse_form
                                parse_path_info
                                accept_yaml

                                riap_client
                                use_tx
                                custom_tx_manager
                        );

use JSON;
use Perinci::Access;
use Perinci::Access::InProcess;
use Perinci::Access::Base::patch::PeriAHS;
use Perinci::Sub::GetArgs::Array qw(get_args_from_array);
use Plack::Util::PeriAHS qw(errpage);
use URI::Escape;

# VERSION

my $json = JSON->new->allow_nonref;

sub prepare_app {
    my $self = shift;

    $self->{match_uri}         //= qr/(?<uri>[^?]*)/;
    $self->{accept_yaml}       //= 0;
    $self->{parse_form}        //= 1;
    $self->{parse_path_info}   //= 0;
    $self->{use_tx}            //= 0;
    $self->{custom_tx_manager} //= undef;

    $self->{riap_client}       //= Perinci::Access->new(
        handlers => {
            pl => Perinci::Access::InProcess->new(
                load => 0,
                extra_wrapper_convert => {
                    #timeout => 300,
                },
                use_tx            => $self->{use_tx},
                custom_tx_manager => $self->{custom_tx_manager},
            ),
        }
    );
}

sub call {
    $log->tracef("=> PeriAHS::ParseRequest middleware");

    my ($self, $env) = @_;

    my $rreq = $env->{"riap.request"} //= {};

    # put Riap client for later phases
    $env->{"periahs.riap_client"} = $self->{riap_client};

    # first determine the default output format (fmt), so we can return error
    # page in that format
    my $acp = $env->{HTTP_ACCEPT} // "";
    my $ua  = $env->{HTTP_USER_AGENT} // "";
    my $fmt;
    if ($acp =~ m!^text/(?:x-)?yaml$!) {
        $fmt = "yaml";
    } elsif ($acp eq 'application/json') {
        $fmt = "json";
    } elsif ($acp eq 'text/plain') {
        $fmt = "text";
    } elsif ($ua =~ m!Wget/|curl/!) {
        $fmt = "text";
    } elsif ($ua =~ m!Mozilla/!) {
        $fmt = "json";
        # XXX enable json->html templating
    } else {
        $fmt = "json";
    }
    $env->{"periahs.default_fmt"} = $fmt;

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
        $rreq->{$k} = $v;
    }

    # parse args from request body (required by spec)
    my $preq = Plack::Request->new($env);
    unless (exists $rreq->{args}) {
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
                eval { $rreq->{args} = $json->decode($preq->content) };
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
                eval { $rreq->{args} = YAML::Syck::Load($preq->content) };
                return errpage(
                    $env, [400, "Invalid YAML in request body"]) if $@;
            }
        }
    }
    return errpage(
        $env, [400, "Riap request key 'args' must be hash"])
        unless !defined($rreq->{args}) || ref($rreq->{args}) eq 'HASH'; # sanity

    # get uri from 'match_uri' config
    my $mu  = $self->{match_uri};
    my $uri = $env->{REQUEST_URI};
    my %m;
    if (ref($mu) eq 'ARRAY') {
        $uri =~ $mu->[0] or return errpage(
            $env, [404, "Request does not match match_uri[0] $mu->[0]"]);
        %m = %+;
        $mu->[1]->($env, \%m);
    } else {
        $uri =~ $mu or return errpage(
            $env, [404, "Request does not match match_uri $mu"]);
        %m = %+;
        for (keys %m) {
            $rreq->{$_} //= $m{$_};
        }
    }

    # get ss request key from form variables (optional)
    if ($self->{parse_form}) {
        my $form = $preq->parameters;

        # special name 'callback' is for jsonp
        if (($rreq->{fmt} // $env->{"periahs.default_fmt"}) eq 'json' &&
                defined($form->{callback})) {
            return errpage(
                $env, [400, "Invalid callback syntax, please use ".
                           "a valid JS identifier"])
                unless $form->{callback} =~ /\A[A-Za-z_]\w*\z/;
            $env->{"periahs.jsonp_callback"} = $form->{callback};
            delete $form->{callback};
        }

        while (my ($k, $v) = each %$form) {
            if ($k =~ /(.+):j$/) {
                $k = $1;
                #$log->trace("CGI parameter $k (json)=$v");
                eval { $v = $json->decode($v) };
                return errpage(
                    $env, [400, "Invalid JSON in query parameter $k: $@"])
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
                $rreq->{$rk} //= $v;
            } else {
                $rreq->{args}{$k} //= $v;
            }
        }
    }

    if ($self->{parse_path_info}) {
        {
            last unless $rreq->{uri};
            my $res = $self->{riap_client}->request(meta => $rreq->{uri});
            last unless $res->[0] == 200;
            my $meta = $res->[2];
            last unless $meta;
            last unless $meta->{args};

            my $pi = $env->{PATH_INFO} // "";
            $pi =~ s!^/+!!;
            my @pi = map {uri_unescape($_)} split m!/+!, $pi;
            $res = get_args_from_array(array=>\@pi, meta=>$meta);
            return errpage(
                $env, [500, "Bad metadata for function $rreq->{uri}: ".
                           "Can't get arguments: $res->[0] - $res->[1]"])
                unless $res->[0] == 200;
                for my $k (keys %{$res->[2]}) {
                    $rreq->{args}{$k} //= $res->[2]{$k};
                }
        }
    }

    # defaults
    $rreq->{v}      //= 1.1;
    $rreq->{action} //= 'call';
    $rreq->{fmt}    //= $env->{"periahs.default_fmt"};

    # sanity: check required keys
    for (qw/uri v action/) {
        defined($rreq->{$_}) or return errpage(
            $env, [500, "Required Riap request key '$_' has not been defined"]);
    }

    # normalize into URI object
    $rreq->{uri} = $self->{riap_client}->_normalize_uri($rreq->{uri});

    $log->tracef("Riap request: %s", $rreq);

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

Aside from that, this middleware also sets these for convenience of later
middlewares:

=over 4

=item * $env->{'periahs.default_fmt'} => STR

Default output format, will be used for response if C<fmt> is not specified in
Rinci request. Determined using some simple heuristics, i.e. graphical browser
like Firefox or Chrome will get 'HTML', command-line browser like Wget or Curl
will get 'Text', others will get 'json'.

=item * $env->{'periahs.jsonp_callback'} => STR

From form variable C<callback>.

=item * $env->{'periahs.riap_client'} => OBJ

Store the Riap client (instance of L<Perinci::Access>).

=back

=head2 Parsing process

B<From HTTP header and request body>. First parsing is done as per L<Riap::HTTP>
specification's requirement. All C<X-Riap-*> request headers are parsed for Riap
request key. When an unknown header is found, HTTP 400 error is returned. Then,
request body is read for C<args>. C<application/json> document type is accepted,
and also C<text/yaml> (if C<accept_yaml> configuration is enabled).

Additionally, the following are also done:

B<From URI>. Request URI is checked against B<match_uri> configuration. If URI
doesn't match this regex, a 404 error response is returned. It is a convenient
way to check for valid URLs as well as set Riap request keys, like:

 qr!^/api/(?<fmt>json|yaml)/!;

The default C<match_uri> is qr/(?<uri>[^?]*)/.

B<From form variables>. If C<parse_form> is enabled, C<args> request key will be
set (or added) from GET/POST request variables, for example:
http://host/api/foo/bar?a=1&b:j=[2] will set arguments C<a> and C<b> (":j"
suffix means value is JSON-encoded; ":y" is also accepted if the C<accept_yaml>
configurations are enabled). In addition, request variables C<-riap-*> are also
accepted for setting other Riap request keys. Unknown Riap request key or
encoding suffix will result in 400 error.

If request format is JSON and form variable C<callback> is defined, then it is
assumed to specify callback for JSONP instead part of C<args>. "callback(json)"
will be returned instead of just "json".

C<From URI (2, path info)>. If C<parse_path_info> configuration is enabled, and
C<uri> Riap request key has been set (so metadata can be retrieved), C<args>
will be set (or added) from URI path info. See "parse_path_info" in the
configuration documentation.

 http://host/api/v1/Module::Sub/func/a1/a2/a3

will result in ['a1', 'a2', 'a3'] being fed into
L<Perinci::Sub::GetArgs::Array>. An unsuccessful parsing will result in HTTP 400
error.


=head1 CONFIGURATIONS

=over 4

=item * match_uri => REGEX or [REGEX, CODE] (default qr/.?/)

This provides an easy way to extract Riap request keys (typically C<uri>) from
HTTP request's URI. Put named captures inside the regex and it will set the
corresponding Riap request keys, e.g.:

 qr!^/api(?<uri>/[^?]*)!

If you need to do some processing, you can also specify a 2-element array
containing regex and code. When supplied this, the middleware will NOT
automatically set Riap request keys with the named captures; instead, your code
should do it. Code will be supplied ($env, \%match) and should set
$env->{'riap.request'} as needed. An example:

 match_uri => [
     qr!^/api
        (?: /(?<module>[\w.]+)?
          (?: /(?<func>[\w+]+) )?
        )?!x,
     sub {
         my ($env, $match) = @_;
         if (defined $match->{module}) {
             $match->{module} =~ s!\.!/!g;
             $env->{'riap.request'}{uri} = "/$match->{module}/" .
                 ($match->{func} // "");
         }
     }];

Given URI C</api/Foo.Bar/baz>, C<uri> Riap request key will be set to
C</Foo/Bar/baz>.

=item * accept_yaml => BOOL (default 0)

Whether to accept YAML-encoded data in HTTP request body and form for C<args>
Riap request key. If you only want to deal with JSON, keep this off.

=item * parse_form => BOOL (default 1)

Whether to parse C<args> keys and Riap request keys from form (GET/POST)
variable of the name C<-x-riap-*> (notice the prefix dash). If an argument is
already defined (e.g. from request body) or request key is already defined (e.g.
from C<X-Riap-*> HTTP request header), it will be skipped.

=item * parse_path_info => BOOL (default 0)

Whether to parse arguments from $env->{PATH_INFO}. Note that this will require a
Riap C<meta> request to the backend, to get the specification for function
arguments. You'll also most of the time need to prepare the PATH_INFO first.
Example:

 parse_path_info => 1,
 match_uri => [
     qr!^/ga/(?<mod>[^?/]+)(?:
            /?(?:
                (?<func>[^?/]+)?:
                (<pi>/?[^?]*)
            )
        )!x,
     sub {
         my ($env, $m) = @_;
         $m->{mod} =~ s!::!/!g;
         $m->{func} //= "";
         $env->{'riap.request'}{uri} = "/$m->{mod}/$m->{func}";
         $env->{PATH_INFO} = $m->{pi};
     },
 ]

=item * riap_client => OBJ

By default, a L<Perinci::Access> object will be instantiated (and later put into
C<$env->{'periahs.riap_client'}> for the next middlewares) to perform Riap
requests. You can supply a custom object here.

=item * use_tx => BOOL (default 0)

Will be passed to L<Perinci::Access::InProcess> constructor.

=item * custom_tx_manager => STR|CODE

Will be passed to L<Perinci::Access::InProcess> constructor.

=back


=head1 SEE ALSO

L<Perinci::Access::HTTP::Server>

=cut
