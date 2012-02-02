package Plack::Middleware::Periuk::ParseRequest;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Request;
use Plack::Util::Accessor qw(
                                uri_pattern

                                allowed_uri_schemes
                                allowed_commands
                                allowed_modules

                                parse_args_from_web_form
                                parse_args_from_path_info
                                per_arg_encoding

                                accept_yaml
                                accept_phps

                                allow_logs

                                after_parse
                        );

use JSON;
use Plack::Util::Periuk qw(errpage allowed);
use Sub::Spec::GetArgs::Array qw(get_args_from_array);
use Sub::Spec::URI;
use URI::Escape;

# VERSION

my $json = JSON->new->allow_nonref;

sub prepare_app {
    my $self = shift;

    $self->{uri_pattern} //= qr/.?/;

    $self->{allowed_commands}    //= [qw/about call spec
                                           list_mods list_subs usage/];
    $self->{allowed_modules}     //= [];
    $self->{allowed_uri_schemes} //= ['pm'];

    $self->{parse_args_from_web_form}  //= 1;
    $self->{parse_args_from_path_info} //= 1;
    $self->{per_arg_encoding}          //= 1;

    $self->{accept_yaml} //= 1;
    $self->{accept_phps} //= 1;

    $self->{allow_logs} //= 1;
}

my @known_ss_req_keys = qw(command uri args output_format
                           log_level mark_log);
sub call {
    my ($self, $env) = @_;

    my $req_uri = $env->{REQUEST_URI};
    my $pat     = $self->uri_pattern;
    unless ($req_uri =~ s/$pat//) {
        return errpage("Bad URL (doesn't match uri_pattern)");
    }
    $env->{"ss.uri_pattern_matches"} = {%+};

    $env->{"ss.request"} //= {};

    # get SS request keys from HTTP headers (required by spec)
    for my $k0 (keys %$env) {
        next unless $k0 =~ /^HTTP_X_SS_REQ_(.+)(_J_)?$/;
        my $v = $env->{$k0};
        my ($k, $encj) = (lc($1), $2);
        if ($k ~~ @known_ss_req_keys) {
            $env->{"ss.request"}{$k} = $encj ? $json->encode($v) : $v;
        } else {
            return errpage("Unknown SS request key: $k");
        }
    }
    $env->{"ss.request"}{args}    //= {};
    return errpage("args must be hash")
        unless ref($env->{"ss.request"}{args}) eq 'HASH';

    my $req = Plack::Request->new($env);

    my $fmt;
    # get/complete SS request key 'args' from request body headers (required by
    # spec) parse module & sub into uri
    {
        my $args;
        my $ct  = $env->{CONTENT_TYPE};
        last unless $ct;
        return errpage("Unknown request content type") unless
            $ct =~ m!\A(?:
                         application/vnd.php.serialized|
                         application/json|
                         text/yaml)\z!x;
        my $body_fh = $req->body;
        my $body = join "", <$body_fh>;
        if ($ct eq 'application/json') {
            #$log->trace('Request body is JSON');
            eval { $args = $json->decode($body) };
            return errpage("Invalid JSON in request body: $@")
                if $@;
            $fmt = 'json';
        } elsif ($ct eq 'application/vnd.php.serialized') {
            #$log->trace('Request body is PHP serialized');
            return errpage("PHP serialized data unacceptable")
                unless $self->accept_phps;
            request PHP::Serialization;
            eval { $args = PHP::Serialization::unserialize($body) };
            return errpage("Invalid PHP serialized data in request body: ".
                               "$@") if $@;
            $fmt = 'phps';
        } elsif ($ct eq 'text/yaml') {
            #$log->trace('Request body is YAML');
            return errpage("YAML data unacceptable")
                unless $self->accept_yaml;
            require YAML::Syck;
            eval { $args = YAML::Load($body) };
            return errpage("Invalid YAML in request body: $@")
                if $@;
            $fmt = 'yaml';
        }
        return errpage("Arguments must be hash (associative array)")
            unless ref($args) eq 'HASH';
        $env->{"ss.request"}{args}{$_} //= $args->{$_}
            for keys %$args;
    }
    $fmt //= 'json';

    # get ss request key from web form variables (optional)
    if ($self->parse_args_from_web_form) {
        my $form = $req->parameters;

        # special name 'callback' is for jsonp
        if ($fmt eq 'json' && defined($form->{callback})) {
            return errpage("Invalid callback syntax, please use ".
                               "a valid JS identifier")
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
                return errpage("YAML data unacceptable") unless
                    $self->accept_yaml;
                require YAML::Syck;
                eval { $v = YAML::Load($v) };
                return errpage("Invalid YAML in query parameter $k: $@")
                    if $@;
            } elsif ($k =~ /(.+):p$/) {
                $k = $1;
                #$log->trace("PHP serialized parameter $k (php)=$v");
                return errpage("PHP serialized data unacceptable") unless
                    $self->accept_phps;
                require PHP::Serialization;
                eval { $v = PHP::Serialization::unserialize($v) };
                return errpage("Invalid PHP serialized data in ".
                                   "query parameter $k: $@") if $@;
            }
            if ($k =~ /\A-ss-req-([\w-]+)/) {
                my $rk = lc $1; $rk =~ s/-/_/g;
                return errpage("Unknown SS request key `$rk` (from web form)")
                    unless $rk ~~ @known_ss_req_keys;
                $env->{"ss.request"}{$rk} //= $v;
            } else {
                $env->{"ss.request"}{args}{$k} //= $v;
            }
        }
    }

    # get ss request keys from URI
    {
        my $m = $env->{"ss.uri_pattern_matches"};
        for (keys %$m) {
            next unless $_ ~~ @known_ss_req_keys;
            $env->{"ss.request"}{$_} //= $m->{$_};
        }
        if ($m->{module}) {
            $m->{module} =~ s/\W+/::/g;
            $m->{module} =~ s/^:://;
        }
        if ($m->{module} && !$env->{"ss.request"}{uri}) {
            $env->{"ss.request"}{uri} = "pm://$m->{module}".
                ($m->{sub} ? "/$m->{sub}":"");
        }
    }

    # create Sub::Spec::URI object, needed for getting spec
    my $uri = $env->{"ss.request"}{uri};
    my $ssu;
    if ($uri) {
        my ($scheme) = $uri =~ m!^(\w+):!;
        return errpage("Invalid SS request URI: no scheme") unless $scheme;
        return errpage("SS request URI scheme `$scheme` not allowed", 403)
            unless allowed($scheme, $self->allowed_uri_schemes);
        eval { $ssu = Sub::Spec::URI->new($uri) };
        return errpage("Invalid SS request URI `$uri`: $@") if $@;
        $env->{"ss.request"}{uri} = $ssu;
    }

    # get ss request key from path info (optional)
    {
        last unless $self->parse_args_from_path_info;
        last unless $ssu;
        $req_uri =~ s/\?.*//;
        $req_uri =~ s!^/!!;
        last unless $req_uri;

        my $spec;
        eval { $spec = $ssu->spec };
        return errpage("Can't get sub spec from $ssu->{_uri}: $@")
            if $@ || !$spec;

        my @argv = map {uri_unescape($_)} split m!/!, $req_uri;
        my $res = get_args_from_array(array=>\@argv, spec=>$spec);
        return errpage("Can't parse arguments from path info: $res->[1]",
                       $res->[0]) unless $res->[0] == 200;
        for my $k (keys %{$res->[2]}) {
            $env->{'ss.request'}{args}{$k} //= $res->[2]{$k};
        }
    }

    # give app a chance to do more parsing
    $self->after_parse->($self, $env) if $self->after_parse;

    $env->{"ss.request"}{command} //= "call";

    # checks
    {
        return errpage("Setting log_level not allowed", 403)
            if !$self->allow_logs && $env->{"ss.request"}{log_level};

        my $command = $env->{"ss.request"}{command};
        return errpage("Command `$command` not allowed", 403)
            unless allowed($env->{"ss.request"}{command},
                           $self->allowed_commands);

        if ($ssu) {
            my $module = $ssu->module;
            if ($module) {
                return errpage("Module `$module` not allowed", 403)
                    unless allowed($module, $self->allowed_modules);
            }
        }
    }

    #use Data::Dump qw(dump); warn dump($env->{"ss.request"});

    # continue to app
    $self->app->($env);
}

1;
# ABSTRACT: Parse HTTP request into SS request

=head1 SYNOPSIS

 # in your app.psgi
 use Plack::Builder;

 builder {
     enable "Periuk::ParseRequest",
         uri_pattern => m!^/api/v1/(?<module>[^?]+)?/?(?<sub>[^?/]+)?!,
         allowed_modules => qr/^My::API/;
 };


=head1 DESCRIPTION

This middleware parses SS request from HTTP request (PSGI environment) and
should normally be the first middleware put in the stack.

=head2 Parsing result

The result of parsing will be put in 'ss.request' PSGI environment key.

=head2 Parsing process

B<From HTTP header and request body>. The parsing is done as per
L<Sub::Spec::HTTP> specification. First, all C<X-SS-Req-*> request headers are
parsed for SS request key. When an unknown header is found, HTTP 400 error is
returned. Then, request body is read for arguments. 'application/json' document
type is accepted, and also 'text/yaml' (if C<accept_yaml> configuration is
enabled) and 'application/vnd.php.serialized' (if C<accept_phps> configuration
is enabled).

Additionally, the following are also done:

B<From URI>. Request URI is checked against B<uri_pattern> configuration. If URI
doesn't match this regex, a 400 error response is returned. It is a convenient
way to check for valid URLs as well as set SS request keys, like:

 qr!^/api/(?<output_format>json|yaml)/!;

Other named captures not matching known SS request keys will be stored in
$env->{"ss.uri_pattern_matches"}. For convenience, C<module> and/or C<sub> will
be used to set C<uri> (if it's not already defined). For example:

 qr!^/api/v1/(?<module>[^?/]+)/(?<sub>[^?/]+)!

will set C<uri> to "pm:$+{module}/$+{sub}". For convenience, C<module> is also
preprocessed, all nonalphanumeric character groups will be converted to "::".

The default C<uri_pattern> is qr/.?/, which matches anything, but won't
parse/capture any information.

B<From web form variables>. If C<parse_args_from_web_form> is enabled, C<args>
request key will be set (or added) from GET/POST request variables, for example:
http://host/api/foo/bar?a=1&b:j=[2] will set arguments C<a> and C<b> (":j"
suffix means value is JSON-encoded; ":y" and ":p" are also accepted if the
C<accept_yaml> and C<accept_phps> configurations are enabled). In addition,
request variables C<-ss-req-*> are also accepted for setting other SS request
keys. Unknown SS request key or encoding suffix will result in 400 error.

If request format is JSON and web form variable C<callback> is defined, then it
is assumed to specify callback for JSONP instead part of C<args>.
"callback(json)" will be returned instead of just "json".

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

=item * uri_pattern => REGEX (default qr/.?/)

Regexp with named captures to match against URI, to extract SS request keys
from. Additionally, C<module> and C<sub> are also converted into 'pm' URI, if
C<uri> is not already specified.

If regexp doesn't match, a 400 error response will be generated.

=item * allowed_uri_schemes => ARRAY|REGEX (default ['pm'])

Which URI schemes are allowed. If SS request's C<uri> has a scheme not on this
list, a HTTP 403 error will be returned.

=item * allowed_commands => ARRAY|REGEX (default [qw/about call help list_mods list_subs spec usage/])

Which commands to allow. Default is all commands. If you want to disable certain
commands, exclude it from the list. In principle the most important command is
'call', while the others are just helpers.

=item * allowed_modules => ARRAY|REGEX (default [])

Which modules to allow. Needs to be set.

=item * parse_args_from_web_form => BOOL (default 1)

Whether to parse arguments from web form (GET/POST parameters). If an argument
is already defined (e.g. via X-SS-Req-* HTTP header), it will be skipped.

=item * parse_args_from_path_info => BOOL (default 1)

Whether to parse arguments from path info. This will only be done if C<uri>
contains module and subroutine name, so its spec can be retrieved (spec is
required for parsing from PATH_INFO).

removed from URI before args are extracted. Also, parsing arguments from path
info (array form, C</arg0/arg1/...>) requires that we have the sub spec first.
So we need to execute the L<Plack::Middleware::Periuk::LoadSpec> first. The
actual parsing is done by L<Plack::Middleware::Periuk::ParseArgsFromPathInfo>
first.

=item * accept_phps => BOOL (default 1)

Whether to accept PHP serialization-encoded data (either in GET/POST request
variables, etc). If you only want to deal with, say, JSON encoding, you might
want to turn this off.

=item * accept_yaml => BOOL (default 1)

Whether to accept YAML-encoded data (either in GET/POST request variables, etc).
If you only want to deal with, say, JSON encoding, you might want to turn this
off.

=item * per_arg_encoding => BOOL (default 1)

Whether we should allow each GET/POST request variable to be encoded, e.g.
http://foo?arg1:j=%5B1,2,3%5D ({arg1=>[1, 2, 3]}).

=item * allow_logs => BOOL (default 1)

Whether to allow request for returning log messages (request option 'log_level'
with value larger than 0). You might want to turn this off on production
servers.

=item * after_parse => CODE

If set, the specified code will be called with arguments ($self, $env) to allow
doing more parsing/checks.

=back


=head1 SEE ALSO

L<Sub::Spec::HTTP>

L<Sub::Spec::HTTP::Client>

=cut
