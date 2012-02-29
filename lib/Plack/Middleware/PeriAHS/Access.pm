1;
# ABSTRACT: Deny access based on some criteria

=item * allow_logs => BOOL (default 1)

Whether to allow request for returning log messages (request option 'log_level'
with value larger than 0). You might want to turn this off on production
servers.

=item * allowed_uri_schemes => ARRAY|REGEX (default ['pm'])

Which URI schemes are allowed. If SS request's C<uri> has a scheme not on this
list, a HTTP 403 error will be returned.

=item * allowed_uris => ARRAY|REGEX (default ['pm'])

=item * allowed_commands => ARRAY|REGEX (default [qw/about call help list_mods list_subs spec usage/])

Which commands to allow. Default is all commands. If you want to disable certain
commands, exclude it from the list. In principle the most important command is
'call', while the others are just helpers.

