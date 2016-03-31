use Modern::Perl;
$ENV{SWAGGER2_DEBUG} = 1;
use lib '../lib/';
use lib '../';

use Test::Mojo;
use Test::More;
use Mojo::Parameters;
use Mojolicious;

require_ok('Mojolicious::Plugin::Swagger2');
use Mojolicious::Plugin::Swagger2;

subtest "CORS internals", \&CORSInternals;
sub CORSInternals {
  my ($xcors, $swagger2path, $swagger2pathSpec, $retVal);

  ##########################
  ### x-cors happy path! ###
  ##x-cors defaults
  $xcors = {
    'x-cors-access-control-allow-origin-list' => 'http://cors.example.com /^https:\/\/.*kirjasto.*$/',
    'x-cors-access-control-allow-credentials' => 'true',
    'x-cors-access-control-allow-methods' => 'GET, POST, DELETE',
  };

  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowOrigin($xcors, undef, undef);
  is($retVal->[0], 'http://cors.example.com', 'Default _handleAccessControlAllowOrigin() static url');
  is(ref $retVal->[1], 'Regexp', 'Default _handleAccessControlAllowOrigin() regexp');
  my $regexp = $retVal->[1];
  ok('https://testi.kirjasto.fi:9999' =~ /$regexp/, 'Default _handleAccessControlAllowOrigin() regexp successfully parsed');
  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowCredentials($xcors, undef, undef);
  is($retVal, 'true', 'Default _handleAccessControlAllowCredentials()');
  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowMethods($xcors, undef, undef);
  is($retVal, 'GET, POST, DELETE', 'Default _handleAccessControlAllowMethods()');

  ##x-cors path spec
  $swagger2path = '/api/cors-pets';
  $swagger2pathSpec = {
    'x-cors-access-control-allow-origin-list' => '*',
    'x-cors-access-control-allow-credentials' => 'false',
    'x-cors-access-control-allow-methods' => 'HEAD',
  };

  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowOrigin(undef, $swagger2path, $swagger2pathSpec);
  is($retVal->[0], '*', 'Path not implemented _handleAccessControlAllowOrigin()');
  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowCredentials(undef, $swagger2path, $swagger2pathSpec);
  is($retVal, 'false', 'Path _handleAccessControlAllowCredentials()');
  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowMethods(undef, $swagger2path, $swagger2pathSpec);
  is($retVal, 'HEAD', 'Path _handleAccessControlAllowMethods()');

  ##x-cors path undef
  $swagger2pathSpec = {};
  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowOrigin(undef, $swagger2path, $swagger2pathSpec);
  is($retVal, undef, 'Path undef _handleAccessControlAllowOrigin()');
  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowCredentials(undef, $swagger2path, $swagger2pathSpec);
  is($retVal, undef, 'Path undef _handleAccessControlAllowCredentials()');
  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowMethods(undef, $swagger2path, $swagger2pathSpec);
  is($retVal, undef, 'Path _handleAccessControlAllowMethods()');


  ##########################
  ### x-cors error cases ###
  ##x-cors defaults
  $xcors = {
    'x-cors-access-control-allow-origin-list' => 'this is bad',
    'x-cors-access-control-allow-credentials' => 'trueish',
    'x-cors-access-control-allow-methods' => 'SLARP, SLURP, DARP',
  };

  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowOrigin($xcors, undef, undef);
  is($retVal->[0], 'this', 'Default error cannot be detected _handleAccessControlAllowOrigin()');
  is($retVal->[1], 'is',   'Default error cannot be detected _handleAccessControlAllowOrigin()');
  is($retVal->[2], 'bad',  'Default error cannot be detected _handleAccessControlAllowOrigin()');
  eval {$retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowCredentials($xcors, undef, undef)};
  ok($@ =~ /value for CORS header 'Access-Control-Allow-Credentials' must be 'true'/, 'Default error _handleAccessControlAllowCredentials()');
  eval {$retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowMethods($xcors, undef, undef)};
  ok($@ =~ /CORS directive 'x-cors-access-control-allow-methods' is not well formed./, 'Default error _handleAccessControlAllowMethods()');

  ################################
  ### x-cors default overloads ###
  $xcors = {
    'x-cors-access-control-allow-origin-list' => 'http://cors.example.com /^.*kirjasto.*$/',
    'x-cors-access-control-allow-credentials' => 'true',
    'x-cors-access-control-allow-methods' => 'GET, POST, DELETE',
  };
  $swagger2path = '/api/cors-pets';
  $swagger2pathSpec = {
    'x-cors-access-control-allow-origin-list' => '*',
    'x-cors-access-control-allow-credentials' => 'false',
    'x-cors-access-control-allow-methods' => 'HEAD',
  };

  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowOrigin($xcors, $swagger2path, $swagger2pathSpec);
  is($retVal->[0], '*', 'Default overloaded _handleAccessControlAllowOrigin()');
  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowCredentials($xcors, $swagger2path, $swagger2pathSpec);
  is($retVal, 'false', 'Default overloaded _handleAccessControlAllowCredentials()');
  $retVal = Mojolicious::Plugin::Swagger2->_handleAccessControlAllowMethods($xcors, $swagger2path, $swagger2pathSpec);
  is($retVal, 'HEAD', 'Default overloaded _handleAccessControlAllowMethods()');

  ##x-cors path spec

}

subtest "Simple CORS", \&simpleCORS;
sub simpleCORS {
  my ($app, $t, $ua, $tx, $headers, $json, $body);

  $app = Mojolicious->new;
  $app->plugin(Swagger2 => {url => "data://main/preflight.json"});
  $t = Test::Mojo->new($app);

  ## Make a GET request from remote Origin ##
  $ua = $t->ua;
  $tx = $ua->build_tx(GET => '/api/cors-pets' => {Accept => '*/*'});
  $tx->req->headers->add('Origin' => 'http://cors.example.com:9999');
  $tx = $ua->start($tx);

  is($tx->res->code, 200, "GET request 200 from allowed Origin");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      'http://cors.example.com:9999',   "Access-Control-Allow-Origin");
  is($headers->header('Access-Control-Allow-Methods'),     undef,                            "Access-Control-Allow-Methods undef");
  is($headers->header('Access-Control-Allow-Headers'),     undef,                            "Access-Control-Allow-Headers undef");
  is($headers->header('Access-Control-Allow-Credentials'), undef,                            "Access-Control-Allow-Credentials undef. Only preflight can set this");
  $json = $tx->res->json;
  is($json->{pet1}, 'George',   "Got George...");
  is($json->{pet2}, 'Georgina', "...and Georgina");

  ## Make a GET request from remote Origin, but we wont permit it. ##
  $ua = $t->ua;
  $tx = $ua->build_tx(GET => '/api/cors-pets' => {Accept => '*/*'});
  $tx->req->headers->add('Origin' => 'http://fake-cors.example.com:9999');
  $tx = $ua->start($tx);

  is($tx->res->code, 403, "GET request 403 from disallowed Origin");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      undef, "Access-Control-Allow-Origin undef");
  is($headers->header('Access-Control-Allow-Methods'),     undef, "Access-Control-Allow-Methods undef");
  is($headers->header('Access-Control-Allow-Headers'),     undef, "Access-Control-Allow-Headers undef");
  is($headers->header('Access-Control-Allow-Credentials'), undef, "Access-Control-Allow-Credentials undef");
  $body = $tx->res->body;
  is($body, "Origin 'http://fake-cors.example.com:9999' not allowed", "Origin not allowed");

  ## Make a GET request from local domain ##
  $ua = $t->ua;
  $tx = $ua->build_tx(GET => '/api/cors-pets' => {Accept => '*/*'});
  $tx = $ua->start($tx);

  is($tx->res->code, 200, "GET request 200 from local domain");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      undef, "Access-Control-Allow-Origin undef");
  is($headers->header('Access-Control-Allow-Methods'),     undef, "Access-Control-Allow-Methods undef");
  is($headers->header('Access-Control-Allow-Headers'),     undef, "Access-Control-Allow-Headers undef");
  is($headers->header('Access-Control-Allow-Credentials'), undef, "Access-Control-Allow-Credentials undef");
  $json = $tx->res->json;
  is($json->{pet1}, 'George',   "Got George...");
  is($json->{pet2}, 'Georgina', "...and Georgina");

  #Make a DELETE request from same domain with same origin. This should be allowed since it is actually not a CORS request.
  $ua = $t->ua;
  $tx = $ua->build_tx(DELETE => '/api/cors-pets/1024' => {Accept => '*/*'});
  $tx->req->headers->add('Origin' => 'http://127.0.0.1:9999');
  $tx = $ua->start($tx);

  is($tx->res->code, 204, "DELETE response 204 from local domain with local Origin");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      undef, "Access-Control-Allow-Origin undef");
  is($headers->header('Access-Control-Allow-Methods'),     undef, "Access-Control-Allow-Methods undef");
  is($headers->header('Access-Control-Allow-Headers'),     undef, "Access-Control-Allow-Headers undef");
  is($headers->header('Access-Control-Allow-Credentials'), undef, "Access-Control-Allow-Credentials undef");
  is($tx->res->body, '', "Delete ok");

  #Make a DELETE request from a strange origin without a preflight-request. This must fail!
  $ua = $t->ua;
  $tx = $ua->build_tx(DELETE => '/api/cors-pets/1024' => {Accept => '*/*'});
  $tx->req->headers->add('Origin' => 'http://fake-cors.example.com:9999');
  $tx = $ua->start($tx);

  is($tx->res->code, 403, "DELETE response 403 from strange Origin");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      undef, "Access-Control-Allow-Origin undef");
  is($headers->header('Access-Control-Allow-Methods'),     undef, "Access-Control-Allow-Methods undef");
  is($headers->header('Access-Control-Allow-Headers'),     undef, "Access-Control-Allow-Headers undef");
  is($headers->header('Access-Control-Allow-Credentials'), undef, "Access-Control-Allow-Credentials undef");
  $body = $tx->res->body;
  is($body, "Origin 'http://fake-cors.example.com:9999' not allowed", "Origin not allowed");
}

subtest "Preflight request", \&preflightRequest;
sub preflightRequest {
  my ($app, $t, $ua, $tx, $headers);

  $app = Mojolicious->new;
  $app->plugin(Swagger2 => {url => "data://main/preflight.json"});
  $t = Test::Mojo->new($app);

  #Make a OPTIONS preflight request for following GET-requests :) Mojo-fu!
  $ua = $t->ua;
  $tx = $ua->build_tx(OPTIONS => '/api/cors-pets' => {Accept => '*/*'});
  $tx->req->headers->add('Origin' => 'http://cors.example.com:9999');
  $tx->req->headers->add('Access-Control-Request-Method' => 'GET');
  $tx->req->headers->add('Access-Control-Request-Headers' => 'Timezone-Offset, Sample-Source');
  $tx = $ua->start($tx);

  is($tx->res->code, 204, "Preflight response 204");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      'http://cors.example.com:9999',   "Access-Control-Allow-Origin");
  is($headers->header('Access-Control-Allow-Methods'),     'GET',                            "Access-Control-Allow-Methods");
  is($headers->header('Access-Control-Allow-Headers'),     'Timezone-Offset, Sample-Source', "Access-Control-Allow-Headers");
  is($headers->header('Access-Control-Allow-Credentials'), 'true',                           "Access-Control-Allow-Credentials");

  #Make a OPTIONS preflight request for following DELETE-requests :) Mojo-fu!
  $ua = $t->ua;
  $tx = $ua->build_tx(OPTIONS => '/api/cors-pets/1024' => {Accept => '*/*'});
  $tx->req->headers->add('Origin' => 'http://cors.example.com:9999');
  $tx->req->headers->add('Access-Control-Request-Method' => 'DELETE');
  $tx->req->headers->add('Access-Control-Request-Headers' => 'Timezone-Offset, Sample-Source');
  $tx = $ua->start($tx);

  is($tx->res->code, 204, "Preflight response 204");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      'http://cors.example.com:9999',   "Access-Control-Allow-Origin");
  is($headers->header('Access-Control-Allow-Methods'),     'DELETE',                         "Access-Control-Allow-Methods");
  is($headers->header('Access-Control-Allow-Headers'),     'Timezone-Offset, Sample-Source', "Access-Control-Allow-Headers");
  is($headers->header('Access-Control-Allow-Credentials'), undef,                            "Access-Control-Allow-Credentials default overloaded");
}

__DATA__
@@ preflight.json
{
  "swagger": "2.0",
  "basePath": "/api",
  "info": {
    "version": "1.0",
    "title": "around-action"
  },
  "x-cors": {
    "x-cors-access-control-allow-origin-list": "http://cors.example.com:9999 http://localhost:3012",
    "x-cors-access-control-allow-credentials": "true",
    "x-cors-access-control-allow-methods": "GET, HEAD",
    "x-cors-access-control-max-age": "600"
  },
  "paths": {
    "/cors-pets": {
      "get": {
        "x-mojo-controller": "t::Api",
        "operationId": "corsListPets",
        "responses": {
          "200": {"description": "anything"}
        }
      }
    },
    "/cors-pets/{petId}": {
      "x-cors-access-control-allow-methods": "DELETE",
      "x-cors-access-control-allow-credentials": "false",
      "delete": {
        "x-mojo-controller": "t::Api",
        "operationId": "corsDeletePets",
        "parameters": [
          {
            "name": "petId",
            "in": "path",
            "required": true,
            "type": "integer"
          }
        ],
        "responses": {
          "204": {"description": "delete ok"}
        }
      }
    }
  }
}