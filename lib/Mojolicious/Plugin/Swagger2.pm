package Mojolicious::Plugin::Swagger2;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::JSON;
use Mojo::Loader;
use Mojo::Util 'decamelize';
use Swagger2;
use Swagger2::SchemaValidator;
use constant DEBUG => $ENV{SWAGGER2_DEBUG} || 0;

my $SKIP_OP_RE = qr(By|From|For|In|Of|To|With);

has url             => '';
has _validator      => sub { Swagger2::SchemaValidator->new; };
has _json_validator => sub { JSON::Validator->new; };

sub dispatch_to_swagger {
  return undef unless $_[1]->{op} and $_[1]->{id} and ref $_[1]->{params} eq 'HASH';

  my ($c, $data) = @_;
  my $self     = $c->stash('swagger.plugin');
  my $reply    = sub { $_[0]->send({json => {code => $_[2] || 200, id => $data->{id}, body => $_[1]}}) };
  my $defaults = $self->{route_defaults}{$data->{op}} or return $c->$reply(_error('Unknown operationId.'), 400);
  my ($e, $input, @errors);

  return $c->$reply(_error($e), 501) if $e = _find_action($c, $defaults);

  for my $p (@{$defaults->{swagger_operation_spec}{parameters} || []}) {
    my $name  = $p->{name};
    my $value = $data->{params}{$name} // $p->{default};
    my @e     = $self->_validate_input_value($p, $name => $value);
    $input->{$name} = $value unless @e;
    push @errors, @e;
  }

  return $c->$reply({errors => \@errors}, 400) if @errors;
  return Mojo::IOLoop->delay(
    sub {
      my $delay  = shift;
      my $action = $defaults->{action};
      my $sc     = $delay->data->{sc} = $defaults->{controller}->new(%$c);
      $sc->stash(swagger_operation_spec => $defaults->{swagger_operation_spec});
      $sc->$action($input, $delay->begin);
    },
    sub {
      my $delay  = shift;
      my $data   = shift;
      my $status = shift || 200;
      my @errors = $self->_validate_response($c, $data, $defaults->{swagger_operation_spec}, $status);

      return $c->$reply($data, $status) unless @errors;
      warn "[Swagger2] Invalid response: @errors\n" if DEBUG;
      $c->$reply({errors => \@errors}, 500);
    },
  );
}

sub render_swagger {
  my ($c, $err, $data, $status) = @_;

  return $c->render(json => $err, status => $status) if %$err;
  return $c->render(ref $data ? (json => $data) : (text => $data), status => $status);
}

sub register {
  my ($self, $app, $config) = @_;
  my ($base_path, $paths, $r, $swagger, $defaultCustomPlaceholder, $xcors);

  $swagger = $config->{swagger} || Swagger2->new->load($config->{url} || '"url" is missing');
  $swagger = $swagger->expand;
  $paths   = $swagger->api_spec->get('/paths') || {};

  if ($config->{validate} // 1) {
    my @errors = $swagger->validate;
    die join "\n", "Swagger2: Invalid spec:", @errors if @errors;
  }
  if (!$app->plugins->has_subscribers('swagger_route_added')) {
    $app->hook(swagger_route_added => \&_on_route_added);
  }

  local $config->{coerce} = $config->{coerce} || $ENV{SWAGGER_COERCE_VALUES};
  $self->_validator->coerce($config->{coerce}) if $config->{coerce};
  $self->url($swagger->url);
  $app->helper(dispatch_to_swagger => \&dispatch_to_swagger) unless $app->renderer->get_helper('dispatch_to_swagger');
  $app->helper(render_swagger      => \&render_swagger)      unless $app->renderer->get_helper('render_swagger');

  $r = $config->{route};

  if ($r and !$r->pattern->unparsed) {
    $r->to(swagger => $swagger);
    $r = $r->any($swagger->base_url->path->to_string);
  }
  if (!$r) {
    $r = $app->routes->any($swagger->base_url->path->to_string);
    $r->to(swagger => $swagger);
  }
  if (my $ws = $config->{ws}) {
    $ws->to('swagger.plugin' => $self);
  }
  $xcors = $self->_use_CORS($app, $swagger);
  $self->_set_default_CORS($r, $xcors) if $xcors;

  $base_path = $swagger->api_spec->data->{basePath} = $r->to_string;
  $base_path =~ s!/$!!;
  $defaultCustomPlaceholder = $swagger->api_spec->data->{'x-mojo-placeholder'} || ':';

  sub replace_route_placeholders {
    my ($route_path, $parameters, $defaultCustomPlaceholder) = @_;
    $route_path =~ s/{([^}]+)}/{
      my $name = $1;
      my $type = ($parameters && $parameters->{$name}) ? $parameters->{$name}{'x-mojo-placeholder'} || $defaultCustomPlaceholder : $defaultCustomPlaceholder;
      "($type$name)";
    }/ge;
    return $route_path;
  }

  for my $path (sort { length $a <=> length $b } keys %$paths) {
    my $around_action = $paths->{$path}{'x-mojo-around-action'} || $swagger->api_spec->get('/x-mojo-around-action');
    my $controller    = $paths->{$path}{'x-mojo-controller'}    || $swagger->api_spec->get('/x-mojo-controller');

    for my $http_method (grep { !/^x-/ } keys %{$paths->{$path}}) {
      my $op_spec    = $paths->{$path}{$http_method};
      my $route_path = $path;
      my %parameters = map { ($_->{name}, $_) } @{$op_spec->{parameters} || []};

      $route_path = replace_route_placeholders($route_path, \%parameters, $defaultCustomPlaceholder);

      $op_spec->{'x-mojo-around-action'} = $around_action if !$op_spec->{'x-mojo-around-action'} and $around_action;
      $op_spec->{'x-mojo-controller'}    = $controller    if !$op_spec->{'x-mojo-controller'}    and $controller;

      my $route_params = {}; #Add params for the route here
      $self->_get_CORS_opts($route_params, $swagger->api_spec->get('/x-cors'), $route_path, $paths->{$path}) if $xcors; #Set CORS options to $route_params

      $app->plugins->emit(
        swagger_route_added => $r->$http_method($route_path => $self->_generate_request_handler($op_spec), $route_params));
      warn "[Swagger2] Add route $http_method $base_path$route_path\n" if DEBUG;
    }

    if ($xcors) { #Configure preflight handlers.
      my $route_path = replace_route_placeholders($path, {}, $defaultCustomPlaceholder); #We should somehow intercept the 'x-mojo-placeholder' of the "Operations Object", but that requires tampering with SecureCORS
      $r->options($route_path => sub {})->to(cb => sub { _cors_preflight($config, @_) });
      warn "[Swagger2][CORS] Add route options $base_path$route_path\n" if DEBUG;
    }
  }

  if (my $spec_path = $config->{spec_path} // '/') {
    my $title = $swagger->api_spec->get('/info/title');
    $title =~ s!\W!_!g;
    $r->get($spec_path)->to(cb => sub { _render_spec(shift, $swagger) })->name(lc $title);
  }
  if ($config->{ensure_swagger_response}) {
    $self->_ensure_swagger_response($app, $config->{ensure_swagger_response}, $swagger);
  }
}

=head2 _use_CORS

  my $corsEnabled = $class->_use_CORS($app, $swagger);

@returns {HashRef} $xcors, the default Swagger2-spec CORS options, if CORS is enabled, otherwise undef.

=cut

sub _use_CORS {
  my ($class, $app, $swagger) = @_;

  my $xcors = $swagger->api_spec->get('/x-cors');
  if (not($xcors)) {
    warn "[Swagger2][CORS] CORS is not needed. See the docs on how to enable it. Not installing preflight handlers or CORS configurations.\n" if DEBUG;
  }
  return $xcors;
}

sub _set_default_CORS {
  my ($class, $r, $xcors) = @_;
  my $corsOpts = $class->_get_CORS_opts(undef, $xcors, undef, undef);

  $r->to(%$corsOpts);
}
sub _get_CORS_opts {
  my ($class, $route_params, $xcors, $path, $pathSpec) = @_;

  my $corsOpts = $route_params || {};
  if (my $credentials = $class->_handleAccessControlAllowCredentials($xcors, $path, $pathSpec)) {
    if (defined($credentials)) {
      $corsOpts->{'cors.credentials'} = ($credentials eq 'true') ? 1 : 0;
    }
  }
  if (my $origin = $class->_handleAccessControlAllowOrigin($xcors, $path, $pathSpec)) {
    if (defined($origin)) {
      $corsOpts->{'cors.origin'} = $origin;
    }
  }
  if (my $methods = $class->_handleAccessControlAllowMethods($xcors, $path, $pathSpec)) {
    if (defined($methods)) {
      $corsOpts->{'cors.methods'} = $methods;
    }
  }
  $corsOpts->{'cors.headers'} = qr/./msi; #Accept all headers as valid CORS headers
  return $corsOpts;
}

=head2 _handleAccessControlAllowCredentials

  my $boolean = $class->_handleAccessControlAllowCredentials($xcors, $path, $pathSpec);

@param {HashRef} $xcors, Swagger2-specifications root definition 'x-cors', which should contain the default CORS options for the whole API.
@param {String} $path, path to this API endpoint.
@param {HashRef} $pathSpec, Swagger2 "Paths Object"
@returns {String Boolean}, 'true', if credentials allowed, 'false' if credentials are explicitly blocked, undef if this not defined and using default|inherited values.
@die if 'x-cors-access-control-allow-credentials' is not 'true' or 'false'. The directive can be missing altogether.

=cut

my $errorMsg_acac = "value for CORS header 'Access-Control-Allow-Credentials' must be 'true' or 'false' or the swagger-directive 'x-cors-access-control-allow-credentials' must not be defined at all.";
sub _handleAccessControlAllowCredentials {
  my ($class, $xcors, $path, $pathSpec) = @_;

  my $default;
  if ($xcors) {
    $default = $xcors->{'x-cors-access-control-allow-credentials'};
    if ($default && $default !~ /^(?:true|false)$/) {
      my @cc = caller(0);
      die $cc[3].":> Default $errorMsg_acac";
    }
  }

  my $pathOverride;
  if ($pathSpec) {
    $pathOverride = $pathSpec->{'x-cors-access-control-allow-credentials'};
    if ($pathOverride && $pathOverride !~ /^(?:true|false)$/) {
      my @cc = caller(0);
      die $cc[3].":> Path '$path', $errorMsg_acac";
    }
  }
  return 'true' if  ($default && $default eq 'true'  && (not($pathOverride) || $pathOverride ne 'false')) || ($pathOverride && $pathOverride eq 'true');
  return 'false' if ($default && $default eq 'false' && (not($pathOverride) || $pathOverride ne 'true'))  || ($pathOverride && $pathOverride eq 'false');
  return undef;
}
sub _handleAccessControlAllowOrigin {
  my ($class, $xcors, $path, $pathSpec) = @_;

  my $default;
  if ($xcors) {
    $default = $xcors->{'x-cors-access-control-allow-origin-list'};
  }

  my $pathOverride;
  if ($pathSpec) {
    $pathOverride = $pathSpec->{'x-cors-access-control-allow-origin-list'};
  }

  my $origins = $pathOverride || $default;
  return undef unless $origins;

  my @origins = map {
    if ($_ =~ m!^/(.*)/$!) { #This is a regexp, so cast it as such
      qr($1);
    }
    else {
      $_;
    }
  } split(/\s+/, $origins);
  return \@origins;
}
my $errorMsg_acam = "CORS directive 'x-cors-access-control-allow-methods' is not well formed. It should consist of a comma separated list of HTTP verbs, or be an empty string or completely missing from the Swagger2-spec.";
sub _handleAccessControlAllowMethods {
  my ($class, $xcors, $path, $pathSpec) = @_;

  sub _validateACAM {
    my $acam = shift;
    unless ($acam =~ /^(?&VERB)?(?:\s*,\s*(?&VERB))*$
                      (?(DEFINE)
                          (?<VERB>GET|HEAD|POST|PUT|DELETE|TRACE|OPTIONS|CONNECT|PATCH)
                      )/x) {
      return undef;
    }
    return 1;
  }

  my $default;
  if ($xcors) {
    $default = $xcors->{'x-cors-access-control-allow-methods'};
    unless (_validateACAM($default || '')) {
      my @cc = caller(0);
      die $cc[3].":> Default $errorMsg_acam";
    }
  }

  my $pathOverride;
  if ($pathSpec) {
    $pathOverride = $pathSpec->{'x-cors-access-control-allow-methods'};
    unless (_validateACAM($pathOverride || '')) {
      my @cc = caller(0);
      die $cc[3].":> Path '$path', $errorMsg_acam";
    }
  }

  return $pathOverride if $pathOverride;
  return $default;
}

sub _cors_simple {
  my ($class, $c) = @_;

  ##We can skip generating CORS headers if this request doesn't demand CORS.
  my $origin = $c->req->headers->origin;
  if (not($origin)) {
    return undef; #This is not a CORS-request, or if it is the browser will block the request.
  }
  my $absUrl = $c->req->url->to_abs;
  my $serverUrl = $absUrl->scheme.'://'.$absUrl->host;
  if ($origin =~ /^\Q$serverUrl\E/) {
    return undef; #Origin defined but is actually local host.
  }
  ##So we actually do need to make the CORS headers

  my $h = $c->res->headers;
  $h->append(Vary => 'Origin'); #Set this to prevent caching whatever result we return

  #Get options inheritable to this endpoint
  my $opt = _get_opt($c->match->endpoint);
  my @errors;

  ##For simple CORS we need less headers
  _cors_response_check_origin($c, $h, $opt, \@errors);

  ## Report CORS errors ##
  return $c->render(status => 403, data => join(", ", @errors)) if @errors;

  return undef; #All is fine! Headers set! Full speed ahead!
}
sub _cors_preflight {
  my ($conf, $c) = @_;

  my $h = $c->res->headers;
  $h->append(Vary => 'Origin'); #Set this to prevent caching whatever result we return

  #Get options inheritable to this endpoint
  my $opt = _get_opt($c->match->endpoint);
  my @errors; #Collect all CORS errors here before returning a possible failure message

  ## Access-Control-Allow-Methods ##
  my $method = $c->req->headers->header('Access-Control-Request-Method');
  my $methodOk;
  if ($opt->{methods}) {
      my %good_methods = map {lc $_ => 1} split /\s*,\s*/ms, $opt->{methods};
      if ($good_methods{lc $method}) {
        $methodOk = 1;
        $h->header('Access-Control-Allow-Methods' => $method) if(not(@errors));
      }
  }
  push @errors, "Method '$method' not allowed" if not($methodOk);

  ## Access-Control-Allow-Origin ##
  _cors_response_check_origin($c, $h, $opt, \@errors);

  ## Report CORS errors, before headers are attached to the request ##
  return $c->render(status => 204, data => join(", ", @errors)) if @errors;

  ## Access-Control-Allow-Headers ## Allow all headers. There can be potentially gazillion headers and checking all of them is expensive O(n^2)
  my $headers = $c->req->headers->header('Access-Control-Request-Headers');
  $h->header('Access-Control-Allow-Headers' => $headers) if $headers;

  ## Access-Control-Allow-Credentials ##
  $h->header('Access-Control-Allow-Credentials' => 'true') if ($opt->{credentials});

  ## Access-Control-Max-Age ##
  $h->header('Access-Control-Max-Age' => $conf->{cors_max_age} || 3600);

  return $c->render(status => 204, data => q{});
}

=head2 _cors_response_check_origin

  my $errors = _cors_response_check_origin($controller, $headers, $opt);

@param {Mojolicious::Controller} $c
@param {Mojo::Headers} $h
@param {HashRef} $opt, CORS options
@param {ArrayRef} $errors, Any previous errors happened when processing the CORS
@returns {ArrayRef of Strings}, the error descriptions if errors happened

=cut

sub _cors_response_check_origin {
  my ($c, $h, $opt, $errors) = @_;
  $errors = [] unless $errors;

  my $origin = $c->req->headers->origin;
  my $allowedOrigins = $opt->{origin};
  my $originOk;
  if (ref $allowedOrigins eq 'ARRAY') {
    foreach my $ao (@$allowedOrigins) {
      if ((ref $ao eq 'Regexp' && $origin =~ /$ao/ms) || #Match regexp
          ($ao eq '*' || $ao eq $origin) #or match anything or exact match
          ) {
        $originOk = 1;
        $h->header('Access-Control-Allow-Origin' => $origin) if(not(@$errors));
        return;
      }
    }
  }
  push @$errors, "Origin '$origin' not allowed" if not($originOk);
}

=head2 _get_opt

  my $opts = _get_opt($route);

Recursively looks for CORS-options starting from the given route and ending at root route.
@returns {HashRef} CORS-options

=cut

sub _get_opt {
    my ($r) = @_;
    my %opt;
    while ($r) {
        for my $name (qw( origin credentials expose headers methods )) {
            if (!exists $opt{$name} && exists $r->to->{"cors.$name"}) {
                $opt{$name} = $r->to->{"cors.$name"};
            }
        }
        $r = $r->parent;
    }
    return \%opt;
}

sub _ensure_swagger_response {
  my ($self, $app, $responses, $swagger) = @_;
  my $base_path = $swagger->api_spec->data->{basePath};

  $responses->{exception} ||= 'Internal server error.';
  $responses->{not_found} ||= 'Not found.';
  $base_path = qr{^$base_path};

  $app->hook(
    before_render => sub {
      my ($c, $args) = @_;

      return unless my $template = $args->{template};
      return unless my $msg      = $responses->{$template};
      return unless $c->req->url->path->to_string =~ $base_path;

      $args->{json} = _error($msg);
    }
  );
}

sub _generate_request_handler {
  my ($self, $op_spec) = @_;
  my $defaults = {swagger_operation_spec => $op_spec};

  my $handler = sub {
    my $c = shift;
    my ($e, $v, $input);

    return $c->render_swagger(_error($e), {}, 501) if $e = _find_action($c, $defaults);
    $c = $defaults->{controller}->new(%$c);

    return if $self->_cors_simple($c); #Return if we get an error

    ($v, $input) = $self->_validate_input($c, $op_spec);

    return $c->render_swagger($v, {}, 400) if @{$v->{errors}};
    return $c->delay(
      sub {
        my $action = $defaults->{action};
        $c->app->log->debug(qq(Swagger2 routing to controller "$defaults->{controller}" and action "$action"));
        $c->$action($input, shift->begin);
      },
      sub {
        my $delay  = shift;
        my $data   = shift;
        my $status = shift || 200;
        my @errors = $self->_validate_response($c, $data, $op_spec, $status);

        return $c->render_swagger({}, $data, $status) unless @errors;
        warn "[Swagger2] Invalid response: @errors\n" if DEBUG;
        $c->render_swagger({errors => \@errors}, $data, 500);
      },
    );
  };

  for my $p (@{$op_spec->{parameters} || []}) {
    $defaults->{$p->{name}} = $p->{default} if $p->{in} eq 'path' and defined $p->{default};
  }

  if (my $around_action = $op_spec->{'x-mojo-around-action'}) {
    my $next = $handler;
    $handler = sub {
      my $c = shift;
      my $around = $c->can($around_action) || $around_action;
      $around->($next, $c, $op_spec);
    };
  }

  $self->{route_defaults}{$op_spec->{operationId}} = $defaults;
  return $defaults, $handler;
}

sub _on_route_added {
  my ($self, $r) = @_;
  my $op_spec    = $r->pattern->defaults->{swagger_operation_spec};
  my $controller = $op_spec->{'x-mojo-controller'};
  my $route_name;

  $route_name = $controller
    ? decamelize join '::', map { ucfirst $_ } $controller, $op_spec->{operationId}
    : decamelize $op_spec->{operationId};

  $route_name =~ s/\W+/_/g;
  $r->name($route_name);
}

sub _render_spec {
  my ($c, $swagger) = @_;
  my $spec = $swagger->api_spec->data;

  local $spec->{id};
  delete $spec->{id};
  local $spec->{host} = $c->req->url->to_abs->host_port;
  $c->render(json => $spec);
}

sub _validate_input {
  my ($self, $c, $op_spec) = @_;
  my (%cache, %input, @errors);

  for my $p (@{$op_spec->{parameters} || []}) {
    my ($in, $name, $type) = @$p{qw( in name type )};
    my ($exists, $value);

    if ($in eq 'body') {
      $value  = $c->req->json;
      $exists = $c->req->body_size;
    }
    else {
      $value = $cache{$in} ||= do {
            $in eq 'query'    ? $c->req->url->query->to_hash
          : $in eq 'path'     ? $c->match->stack->[-1]
          : $in eq 'formData' ? $c->req->body_params->to_hash
          : $in eq 'header'   ? $c->req->headers->to_hash
          :                     {};
      };
      $exists = exists $value->{$name};
      $value  = $value->{$name};
    }

    if (ref $p->{items} eq 'HASH' and $p->{collectionFormat}) {
      $value = _coerce_by_collection_format($value, $p);
    }

    if ($type and defined($value //= $p->{default})) {
      if (($type eq 'integer' or $type eq 'number') and $value =~ /^-?\d/) {
        $value += 0;
      }
      elsif ($type eq 'boolean') {
        $value = (!$value or $value eq 'false') ? Mojo::JSON->false : Mojo::JSON->true;
      }
    }

    my @e = $self->_validate_input_value($p, $name => $value);
    $input{$name} = $value if !@e and ($exists or exists $p->{default});
    push @errors, @e;
  }

  return {errors => \@errors}, \%input;
}

sub _validate_input_value {
  my ($self, $p, $name, $value) = @_;
  my $type = $p->{type} || 'object';
  my @e;

  return if !defined $value and !Swagger2::_is_true($p->{required});

  my $schema = {properties => {$name => $p->{'x-json-schema'} || $p->{schema} || $p},
    required => [$p->{required} ? ($name) : ()]};
  my $in = $p->{in};

  if ($in eq 'body') {
    warn "[Swagger2] Validate $in $name\n" if DEBUG;
    if ($p->{'x-json-schema'}) {
      return $self->_json_validator->validate({$name => $value}, $schema);
    }
    else {
      return $self->_validator->validate_input({$name => $value}, $schema);
    }
  }
  elsif (defined $value) {
    warn "[Swagger2] Validate $in $name=$value\n" if DEBUG;
    return $self->_validator->validate_input({$name => $value}, $schema);
  }
  else {
    warn "[Swagger2] Validate $in $name=undef\n" if DEBUG;
    return $self->_validator->validate_input({$name => $value}, $schema);
  }

  return;
}

sub _validate_response {
  my ($self, $c, $data, $op_spec, $status) = @_;
  my $headers = $c->res->headers;
  my @errors;

  if (my $blueprint = $op_spec->{responses}{$status} || $op_spec->{responses}{default}) {
    my $input = $headers->to_hash(1);

    for my $n (keys %{$blueprint->{headers} || {}}) {
      my $p = $blueprint->{headers}{$n};

      # jhthorsen: I think that the only way to make a header required,
      # is by defining "array" and "minItems" >= 1.
      if ($p->{type} eq 'array') {
        push @errors, $self->_validator->validate($input->{$n}, $p);
      }
      elsif ($input->{$n}) {
        push @errors, $self->_validator->validate($input->{$n}[0], $p);
        $headers->header($n => $input->{$n}[0] ? 'true' : 'false') if $p->{type} eq 'boolean' and !@errors;
      }
    }

    if ($blueprint->{'x-json-schema'}) {
      warn "[Swagger2] Validate using x-json-schema\n" if DEBUG;
      push @errors, $self->_json_validator->validate($data, $blueprint->{'x-json-schema'});
    }
    elsif ($blueprint->{schema}) {
      warn "[Swagger2] Validate using schema\n" if DEBUG;
      push @errors, $self->_validator->validate($data, $blueprint->{schema});
    }
  }
  else {
    push @errors, $self->_validator->validate($data, {});
  }

  return @errors;
}

sub _coerce_by_collection_format {
  my ($value, $schema) = @_;
  my $re = $Swagger2::SchemaValidator::COLLECTION_RE{$schema->{collectionFormat}} || '';
  my $type = $schema->{items}{type} || '';
  my @data;

  return [ref $value ? @$value : $value] unless $re;
  defined and push @data, split /$re/ for ref $value ? @$value : $value;
  return [map { $_ + 0 } @data] if $type eq 'integer' or $type eq 'number';
  return \@data;
}

sub _error {
  return {errors => [{message => $_[0], path => '/'}]};
}

sub _find_action {
  return if $_[1]->{controller};    # cached
  my ($c, $defaults) = @_;
  my $op = $defaults->{swagger_operation_spec}{operationId} or return 'operationId is missing.';
  my $can = sub {
    $defaults->{controller}->can($defaults->{action}) ? '' : qq(Method "$defaults->{action}" not implemented.);
  };

  # specify controller manually
  @$defaults{qw( action controller )} = _load($c, $op, $defaults->{swagger_operation_spec}{'x-mojo-controller'});
  return $can->() if $defaults->{controller};

  # "createFileInFileSystem" = ("createFile", "FileSystem")
  @$defaults{qw( action controller )} = _load($c, split $SKIP_OP_RE, $op);
  return $can->() if $defaults->{controller};

  # "showPetById" = "showPet"
  $op =~ s!$SKIP_OP_RE.*$!!;

  # "show_fooPet" = ("show_foo", "Pet")
  @$defaults{qw( action controller )} = _load($c, $op =~ /^([a-z_]+)([A-Z]\w+)$/);
  return $can->() if $defaults->{controller};

  return qq(Controller from operationId "$defaults->{swagger_operation_spec}{operationId}" could not be loaded.);
}

sub _load {
  my ($c, $action, $controller) = @_;
  my (@classes, %uniq);

  return unless $controller;
  $action = decamelize ucfirst $action;

  if ($controller =~ /::/) {
    push @classes, $controller;
  }
  else {
    my $singular = $controller;
    $singular =~ s!s$!!;    # "showPets" = "showPet"
    push @classes,
      grep { !$uniq{$_}++ } map { ("${_}::$controller", "${_}::$singular") } @{$c->app->routes->namespaces};
  }

  while ($controller = shift @classes) {
    my $e = Mojo::Loader::load_class($controller);
    warn qq([Swagger2] Load "$controller": @{[ref $e ? $e : $e ? "Can't locate class" : "Success"]}.\n) if DEBUG;
    return ($action, $controller) if $controller->can('new');
  }

  return;
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Swagger2 - Mojolicious plugin for Swagger2

=head1 SYNOPSIS

  package MyApp;
  use Mojo::Base "Mojolicious";

  sub startup {
    my $app = shift;
    $app->plugin(Swagger2 => {url => "data://MyApp/petstore.json"});
  }

  __DATA__
  @@ petstore.json
  {
    "swagger": "2.0",
    "info": {...},
    "host": "petstore.swagger.wordnik.com",
    "basePath": "/api",
    "paths": {
      "/pets": {
        "get": {...}
      }
    }
  }

=head1 DESCRIPTION

L<Mojolicious::Plugin::Swagger2> is L<Mojolicious::Plugin> that add routes and
input/output validation to your L<Mojolicious> application.

Have a look at the L</RESOURCES> for a complete reference to what is possible
or look at L<Swagger2::Guides::Tutorial> for an introduction.

=head1 RESOURCES

=over 4

=item * L<Swagger2::Guides::Tutorial> - Tutorial for this plugin

=item * L<Swagger2::Guides::Render> - Details about the render process

=item * L<Swagger2::Guides::ProtectedApi> - Protected API Guide

=item * L<Swagger2::Guides::CustomPlaceholder> - Custom placeholder for your routes

=item * L<Swagger2::Guides::JSONSchemaSupport> - Adding json-schema support - EXPERIMENTAL

=item * L<Swagger spec|https://github.com/jhthorsen/swagger2/blob/master/t/blog/api.json>

=item * L<Application|https://github.com/jhthorsen/swagger2/blob/master/t/blog/lib/Blog.pm>

=item * L<Controller|https://github.com/jhthorsen/swagger2/blob/master/t/blog/lib/Blog/Controller/Posts.pm>

=item * L<Tests|https://github.com/jhthorsen/swagger2/blob/master/t/authenticate.t>

=back

=head1 HOOKS

=head2 swagger_route_added

  $app->hook(swagger_route_added => sub {
    my ($app, $r) = @_;
    my $op_spec = $r->pattern->defaults->{swagger_operation_spec};
    # ...
  });

The "swagger_route_added" event will be emitted on the application object
for every route that is added by this plugin. This can be useful if you
want to do things like specifying a custom route name.

=head1 STASH VARIABLES

=head2 swagger

The L<Swagger2> object used to generate the routes is available
as C<swagger> from L<stash|Mojolicious/stash>. Example code:

  sub documentation {
    my ($c, $args, $cb);
    $c->$cb($c->stash('swagger')->pod->to_string, 200);
  }

=head2 swagger_operation_spec

The Swagger specification for the current
L<operation object|https://github.com/swagger-api/swagger-spec/blob/master/versions/2.0.md#operationObject>
is stored in the "swagger_operation_spec" stash variable.

  sub list_pets {
    my ($c, $args, $cb);
    $c->app->log->info($c->stash("swagger_operation_spec")->{operationId});
    ...
  }

=head1 ATTRIBUTES

=head2 url

Holds the URL to the swagger specification file.

=head1 HELPERS

=head2 dispatch_to_swagger

  $bool = $c->dispatch_to_swagger(\%data);

This helper can be used to handle WebSocket requests with swagger.
See L<Swagger2::Guides::WebSocket> for details.

This helper is EXPERIMENTAL.

=head2 render_swagger

  $c->render_swagger(\%err, \%data, $status);

This method is used to render C<%data> from the controller method. The C<%err>
hash will be empty on success, but can contain input/output validation errors.
C<$status> is used to set a proper HTTP status code such as 200, 400 or 500.

See also L<Swagger2::Guides::Render> for more information.

=head1 METHODS

=head2 register

  $self->register($app, \%config);

This method is called when this plugin is registered in the L<Mojolicious>
application.

C<%config> can contain these parameters:

=over 4

=item * coerce

This argument will be passed on to L<JSON::Validator/coerce>.

=item * ensure_swagger_response

  $app->plugin(swagger2 => {
    ensure_swagger_response => {
      exception => "Internal server error.",
      not_found => "Not found.",
    }
  });

Adds a L<before_render|Mojolicious/HOOKS> hook which will make sure
"exception" and "not_found" responses are in JSON format. There is no need to
specify "exception" and "not_found" if you are happy with the defaults.

=item * route

Need to hold a Mojolicious route object. See L</Protected API> for an example.

This parameter is optional.

=item * spec_path

Holds the location for where the specifiation can be served from. The default
value is "/", relative to "basePath" in the specification. Can be disabled
by setting this value to empty string.

=item * validate

A boolean value (default is true) that will cause your schema to be validated.
This plugin will abort loading if the schema include errors

=item * swagger

A C<Swagger2> object. This can be useful if you want to keep use the
specification to other things in your application. Example:

  use Swagger2;
  my $swagger = Swagger2->new->load($url);
  plugin Swagger2 => {swagger => $swagger2};
  app->defaults(swagger_spec => $swagger->api_spec);

Either this parameter or C<url> need to be present.

=item * url

This will be used to construct a new L<Swagger2> object. The C<url>
can be anything that L<Swagger2/load> can handle.

Either this parameter or C<swagger> need to be present.

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014-2015, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut
