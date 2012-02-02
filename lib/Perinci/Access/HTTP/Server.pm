package Perinci::Access::HTTP::Server;

use 5.010;
use strict;
use warnings;

# VERSION

1;
# ABSTRACT: PSGI application to implement Riap::HTTP

=head1 SYNOPSIS

Suppose you want to expose functions in C<My::API::Adder> and
C<My::API::Adder::Array> as HTTP API functions, using URL
http://<host>/api/<module>/<func>:

 package My::API::Adder;
 our %SPEC;
 $SPEC{add} = {args => {a=>["float*"=>{arg_pos=>0}],
                        b=>["float*"=>{arg_pos=>1}]}};
 sub add { my %args=@_; [200, "OK", $args{a}+$args{b}] }
 1;

 package My::API::Adder::Array;
 $SPEC{add_array} = {

     summary => 'Concatenate two arrays together',
     args => {a1=>["array*" => {summary => 'First array'}],
              a2=>["array*" => {summary => 'Second array'}]},
 };
 sub add { my %args=@_; [200, "OK", [@{$args{a1}}, @{$args{a2}}]] }
 1;

 # or just write any normal Perl module without any specs

Then:

 $ servepm My::API::Adder My::API::Adder::Array

Then call your functions over HTTP(S)?:

 % curl http://localhost:5000/My/API/Adder/add?a=2&b=3
 [200,"OK",6]

 % curl -H 'x-riap-loglevel: 6' \
   'http://localhost:5000/My/API/Adder/Array/add_array?a1:j=[1]&a2:j=[2,3]'
 [200,"OK",[1,2,3]]

List available modules:

 % curl -H 'x-riap-action: list' \
   'http://localhost:5000/'
 ['/My/API/Adder/','/My/API/Adder/Array/']


=head1 DESCRIPTION

Perinci::Access::HTTP::I<Server> (a.k.a. L<Periuk>) is a I<PSGI application> (a
set of middlewares, really) to implement L<Riap::HTTP> server. You can use it to
quickly create an API service.

As the case with any PSGI application, you can use any I<PSGI server> to run it
with. You might want to consider L<Gepok>, which has built-in HTTPS support. The
L<servepm> command-line utility uses Gepok.

This PSGI application is actually a set of modular middlewares
(Plack::Middleware::Periuk::*) which you can compose in your app.psgi,
configuring each one and including only the ones you need. The Synopsis shows
one such basic composition. There are more middlewares to do custom stuffs. See
each middleware's documentation for details.

This module uses L<Log::Any> for logging.

This module uses L<Moo> for object system.


=head1 FAQ

=head2 Periuk?

It is an Indonesian word, meaning crock/clay pot, used to cook rice or whatever.
I use this short alias so this namespace not need to happen:
Plack::Middleware::Perinci::Access::HTTP::Server::*.

=head2 I don't want to have to add metadata to every function!

The point of Riap::HTTP is to expose metadata over HTTP, so it's best that you
write your metadata for every API function you want to expose.

However, there are tools like L<Perinci::Gen::ForModule> /
L<Perinci::Sub::Gen::ForModule> which can generate some (generic) metadata for
your existing modules.

=head2 How can I customize URL?

For example, instead of:

 http://localhost:5000/My::API::Adder/func

you want:

 http://localhost:5000/adder/func

or perhaps (if you only have one module to expose):

 http://localhost:5000/func

You can do this by customizing uri_pattern when enabling the
Periuk::ParseRequest middleware (see servepm source code). You just need to make
sure that you produce $env->{"riap.request"}{uri} (and other necessary Riap
request keys).

=head1 I want to let user specify output format from URI (e.g. /api/j/... or /api/yaml/...).

Again, this can be achieved by customizing the Periuk::ParseRequest middleware.
You can do something like:

 enable "Periuk::ParseRequest"
     uri_pattern => qr!^/api/(?<fmt>json|yaml|j|y)/
                       (?<uri>[^?/]+(?:/[^?/]+)?)!x;
     after_parse => sub {
         my $env = shift;
         my $m1 = $env->{"periuk.uri_pattern_matches"}{fmt};
         $env->{"riap.request"}{fmt} = $fmt =~ /j/ ? 'json' : 'yaml';
     };

=head1 I need even more custom URI syntax.

You can leave C<uri_pattern> empty and perform your custom URI parsing in
C<after_parse>. For example:

 enable "Periuk::ParseRequest"
     after_parse => sub {
         my $env = shift;
         # parse $env->{REQUEST_URI} on your own and put the result in
         # $env->{"riap.request"}{uri}
     };

Or alternatively you can write your own request parser to replace
Periuk::ParseRequest.

=head2 I want to support HTTPS.

Supply --https_ports, --ssl_key_file and --ssl_cert_file options in servepm.

If you do not use servepm or use PSGI server other than Gepok, you will probably
need to run Nginx, L<Perlbal>, or some other external HTTPS proxy. Hopefully

=head2 I don't want to expose my subroutines and module structure directly!

Well, isn't exposing functions the whole point of API?

If you have modules that you do not want to expose as API, simply exclude it
(e.g. using C<allowed_modules> configuration in Periuk::ParseRequest middleware.
Or, create a set of wrapper modules to expose only the functionalities that you
want to expose.

=head2 But I want REST-style!

Take a look at L<Serabi>.

=head2 I want to support another output format (e.g. XML, MessagePack, etc).

Add a format_<fmtname> method to L<Plack::Middleware::Periuk::HandleCommand>.
The method accepts sub response and is expected to return a tuplet ($output,
$content_type).

Note that you do not have to modify the Plack/Middleware/Periuk/HandleCommand.pm
file itself. You can inject the method from another file.

Also make sure that the output format is allowed (see configuration
C<allowed_output_formats> in the command handler middleware).

=head2 I want to automatically reload modules that changed on disk.

Use one of the module-reloading module on CPAN, e.g.: L<Module::Reload> or
L<Module::Reload::Conditional>.

=head2 I want to authenticate clients.

Enable L<Plack::Middleware::Auth::Basic> (or other authen middleware you prefer)
before Periuk::ParseRequest.

=head2 I want to authorize clients.

Take a look at L<Plack::Middleware::Periuk::Authz::ACL> which allows
authorization based on various conditions. Normally this is put after
authentication and before command handling.

=head2 I want to support new actions.

Normally you'll need to extend the appropriate Riap clients (e.g.
L<Perinci::Access::InProcess> for this. Again, note that you don't have to
resort to subclassing just to accomplish this. You can inject the
action_ACTION() method from somewhere else.

=head2 I want to serve static files.

Use the usual L<Plack::Builder>'s mount() and L<Plack::Middleware::Static> for
this.

 mount my $app = builder {
     mount "/api" => builder {
         enable "Periuk::ParseRequest", ...;
         ...
     },
     mount "/static" => builder {
         enable "Static", path=>..., root=>...;
     },
 };


=head1 TIPS AND TRICKS

=head2 Proxying API server

Not only can you serve local modules, you can also serve remote modules
("http://" or "https://" URIs) making your API server a proxy for another.

=head2 Performance tuning

To be written.


=head1 TODO

* Improve performance.


=head1 SEE ALSO

L<Riap::HTTP>

L<Serabi>

=cut
