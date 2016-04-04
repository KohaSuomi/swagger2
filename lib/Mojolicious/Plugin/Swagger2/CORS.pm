package Mojolicious::Plugin::Swagger2::CORS;

use constant DEBUG => $ENV{SWAGGER2_DEBUG} || 0;

=head2 use_CORS

  my $xcors = $class->use_CORS($app, $swagger);

Are we using CORS in the Swagger2-definition?
@param {Mojolicious} $app, the Mojolicious application derivative
@param {Swagger2} $swagger, the Swagger2-object containing the local Swagger2-definition
@returns {HashRef} $xcors, the default Swagger2-spec CORS options, if CORS is enabled, otherwise undef.

=cut

sub use_CORS {
  my ($class, $app, $swagger) = @_;

  my $xcors = $swagger->api_spec->get('/x-cors');
  if (not($xcors)) {
    warn "[Swagger2][CORS] CORS is not needed. See the docs on how to enable it. Not installing preflight handlers or CORS configurations.\n" if DEBUG;
  }
  return $xcors;
}

=head set_default_CORS

  $class->set_default_CORS($route, $xcors);

Set default CORS settings for the given route. Is intended to be used for the root API route, from which the child routes can inherit settings.
@param {Mojolicious::Routes::Route} $r, route to CORS:erize
@param {HashRef} $xcors, CORS parameters from use_CORS()

=cut

sub set_default_CORS {
  my ($class, $r, $xcors) = @_;
  my $corsOpts = $class->get_opts(undef, $xcors, undef, undef);

  $r->to(%$corsOpts);
}

=head get_opts

  $class->get_opts($route_params, $xcors, $path, $pathSpec);

Get the CORS-options for the given definitions. API endpoint options override defaults.
@param {HashRef} $route_params, and existing Hash of parameters if you are collecting
                 parameters for a route definition, or if you want to include the
                 CORS-options to an existing data structure.
@param {HashRef} $xcors, default CORS-options from use_CORS();
@param {String} $path, Swagger2-definition path-url to the API endpoint we are getting options for
@param {HashRef} $pathSpec, Swagger2-"Operations object" for the API endpoint.

=cut

sub get_opts {
  my ($class, $route_params, $xcors, $path, $pathSpec) = @_;

  my $corsOpts = $route_params || {};
  if (my $credentials = $class->_handleAccessControlAllowCredentials($xcors, $path, $pathSpec)) {
    $corsOpts->{'cors.credentials'} = ($credentials eq 'true') ? 1 : 0;
  }
  if (my $origin = $class->_handleAccessControlAllowOrigin($xcors, $path, $pathSpec)) {
    $corsOpts->{'cors.origin'} = $origin;
  }
  if (my $methods = $class->_handleAccessControlAllowMethods($xcors, $path, $pathSpec)) {
    $corsOpts->{'cors.methods'} = $methods;
  }
  my $maxAge = $class->_handleAccessControlMaxAge($xcors, $path, $pathSpec);
  if (defined($maxAge)) { #Max age can be 0
    $corsOpts->{'cors.maxAge'} = $maxAge;
  }

  $corsOpts->{'cors.headers'} = qr/./msi; #Accept all headers as valid CORS headers
  $corsOpts->{'cors.expose'}  = qr/./msi; #Expose all headers for the client
  return $corsOpts;
}

=head2 _handleAccessControlAllowCredentials

  my $boolean = $class->_handleAccessControlAllowCredentials($xcors, $path, $pathSpec);

One or both of the params $xcors and $pathSpec must be defined.
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
      die $cc[3].":> Default value '$default', $errorMsg_acac";
    }
  }

  my $pathOverride;
  if ($pathSpec) {
    $pathOverride = $pathSpec->{'x-cors-access-control-allow-credentials'};
    if ($pathOverride && $pathOverride !~ /^(?:true|false)$/) {
      my @cc = caller(0);
      die $cc[3].":> Path '$path' value '$pathOverride', $errorMsg_acac";
    }
  }
  return 'true' if  ($default && $default eq 'true'  && (not($pathOverride) || $pathOverride ne 'false')) || ($pathOverride && $pathOverride eq 'true');
  return 'false' if ($default && $default eq 'false' && (not($pathOverride) || $pathOverride ne 'true'))  || ($pathOverride && $pathOverride eq 'false');
  return undef;
}

my $errorMsg_acma = "value for CORS header 'Access-Control-Max-Age' must be an integer of seconds or the swagger-directive 'x-cors-access-control-max-age' must not be defined at all.";
sub _handleAccessControlMaxAge {
  my ($class, $xcors, $path, $pathSpec) = @_;

  my $default;
  if ($xcors) {
    $default = $xcors->{'x-cors-access-control-max-age'};
    if ($default && $default !~ /^\d+$/) {
      my @cc = caller(0);
      die $cc[3].":> Default value '$default', $errorMsg_acma";
    }
  }

  my $pathOverride;
  if ($pathSpec) {
    $pathOverride = $pathSpec->{'x-cors-access-control-max-age'};
    if ($pathOverride && $pathOverride !~ /^\d+$/) {
      my @cc = caller(0);
      die $cc[3].":> Path '$path' value '$pathOverride', $errorMsg_acma";
    }
  }
  return $pathOverride if defined($pathOverride);
  return $default if defined($default);
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

my $errorMsg_acam = "CORS directive 'x-cors-access-control-allow-methods' is not well formed. It should consist of a comma separated list of HTTP verbs, or be an empty string or a '*' to allow all methods or be completely missing from the Swagger2-spec.";
sub _handleAccessControlAllowMethods {
  my ($class, $xcors, $path, $pathSpec) = @_;

  sub _validateACAM {
    my $acam = shift;
    return 1 if $acam eq '*';
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
      die $cc[3].":> Default value '$default', $errorMsg_acam";
    }
  }

  my $pathOverride;
  if ($pathSpec) {
    $pathOverride = $pathSpec->{'x-cors-access-control-allow-methods'};
    unless (_validateACAM($pathOverride || '')) {
      my @cc = caller(0);
      die $cc[3].":> Path '$path' value '$pathOverride', $errorMsg_acam";
    }
  }

  my $realVal = $pathOverride || $default;
  if ($realVal) {
    my @realVals = split /\s*,\s*/ms, $realVal;
    my %good_methods = map {uc($_) => 1} @realVals;
    return \%good_methods
  }
  return undef;
}

=head is_CORS_request

  my $isCORS = $class->is_CORS_request($c);

@param {Mojolicious::Controller} $c, the controller of the request-response -cycle
@returns {Int Boolean}, 1 if this is a CORS-request, undef if not.

=cut

sub is_CORS_request {
  my ($class, $c) = @_;

  ##We can skip generating CORS headers if this request doesn't have a Origin-header.
  my $origin = $c->req->headers->origin;
  if (not($origin)) {
    return undef; #This is not a CORS-request, or if it is the browser will block the request.
  }
  my $absUrl = $c->req->url->to_abs;
  my $serverUrl = $absUrl->scheme.'://'.$absUrl->host;
  if ($origin =~ /^\Q$serverUrl\E/) {
    return undef; #Origin defined but is actually local host. Abort CORS.
  }

  return 1;
}

sub simple {
  my ($class, $c) = @_;

  return undef unless $class->is_CORS_request($c);

  my $h = $c->res->headers;
  $h->append(Vary => 'Origin'); #Set this to prevent caching whatever result we return

  my @errors;

  ##For simple CORS we need less headers
  _cors_response_check_origin($c, $h, $c->stash('cors.origin'), \@errors);

  ## Report CORS errors ##
  return $c->render(status => 403, data => join(", ", @errors)) if @errors;

  return undef; #All is fine! Headers set! Full speed ahead!
}

sub preflight {
  my ($class, $c) = @_;

  return undef unless $class->is_CORS_request($c);

  my $h = $c->res->headers;
  $h->append(Vary => 'Origin'); #Set this to prevent caching whatever result we return

  my @errors; #Collect all CORS errors here before returning a possible failure message

  ## Access-Control-Allow-Methods ##
  _cors_response_check_method($c, $h, $c->stash('cors.methods'), \@errors);

  ## Access-Control-Allow-Origin ##
  _cors_response_check_origin($c, $h, $c->stash('cors.origin'), \@errors);

  ## Report CORS errors, before headers are attached to the request ##
  return \@errors if @errors;

  ## Access-Control-Allow-Headers  ## Allow all headers. There can be potentially gazillion headers and checking all of them is expensive O(n^2)
  ## Access-Control-Expose-Headers ##
  my $headers = $c->req->headers->header('Access-Control-Request-Headers');
  if ($headers) {
    $h->header('Access-Control-Allow-Headers'  => $headers);
    $h->header('Access-Control-Expose-Headers' => $headers);
  }

  ## Access-Control-Allow-Credentials ##
  $h->header('Access-Control-Allow-Credentials' => 'true') if ($c->stash('cors.credentials'));

  ## Access-Control-Max-Age ##
  $h->header('Access-Control-Max-Age' => $c->stash('cors.maxAge') || 3600);

  return undef;
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
  my ($c, $h, $allowedOrigins, $errors) = @_;
  $errors = [] unless $errors;

  my $origin = $c->req->headers->origin;
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

sub _cors_response_check_method {
  my ($c, $h, $allowedMethods, $errors) = @_;
  $errors = [] unless $errors;

  my $method = $c->req->headers->header('Access-Control-Request-Method');
  my $methodOk;
  if (ref $allowedMethods eq 'HASH') {
    if ($allowedMethods->{'*'}) {
      $methodOk = 1;
      my $allMethods = join(', ', map {uc($_)} sort(@{$c->stash('available_methods')})) if $c->stash('available_methods');
      $h->header('Access-Control-Allow-Methods' => $allMethods || $method) if(not(@errors));
    }
    elsif ($allowedMethods->{uc($method)}) {
      $methodOk = 1;
      $h->header('Access-Control-Allow-Methods' => join(', ', sort(keys(%$allowedMethods)))) if(not(@errors));
    }
  }
  push @$errors, "Method '$method' not allowed" if not($methodOk);
}

1;