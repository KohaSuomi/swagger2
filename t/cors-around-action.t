use Modern::Perl;

use Test::Mojo;
use Test::More;
use Mojo::Parameters;
use Mojolicious;

require_ok('Mojolicious::Plugin::Swagger2');
use Mojolicious::Plugin::Swagger2;

require_ok('Mojolicious::Plugin::Swagger2::CORS');
use Mojolicious::Plugin::Swagger2::CORS;

require_ok('t::CORS');
use t::CORS;

=head1 Implementation notes

Tests have excessive tests for headers which are not defined.
Some CORS implementations have bugs in having headers which should not be set.
To prevent against getting "bad" headers as regression, all known headers are meticulously
inspected.

=cut

subtest "Simple CORS with 'x-mojo-around-action'", \&simpleCORSxMojoAroundAction;
sub simpleCORSxMojoAroundAction {
  my ($app, $t, $ua, $tx, $headers, $json, $body);

  $app = Mojolicious->new;
  $app->plugin(Swagger2 => {url => "data://main/x-mojo-around-action.json"});
  $t = Test::Mojo->new($app);

  ## Make a GET request from remote Origin ##
  $ua = $t->ua;
  $tx = $ua->build_tx(GET => '/api/cors-pets' => {Accept => '*/*'});
  $tx->req->headers->add('Origin' => 'http://cors.example.com:9999');
  $tx = $ua->start($tx);

  is($tx->res->code, 401, "GET request 401 from allowed Origin. CORS ok, 'x-mojo-around-action' fails.");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      'http://cors.example.com:9999',   "Access-Control-Allow-Origin");
  is($headers->header('Access-Control-Allow-Methods'),     undef,                            "Access-Control-Allow-Methods undef");
  is($headers->header('Access-Control-Allow-Headers'),     undef,                            "Access-Control-Allow-Headers undef");
  is($headers->header('Access-Control-Expose-Headers'),    undef,                            "Access-Control-Expose-Headers undef");
  is($headers->header('Access-Control-Allow-Credentials'), undef,                            "Access-Control-Allow-Credentials undef. Only preflight can set this");
  $json = $tx->res->json;
  is($json->{errors}->[0]->{message}, 'Always fail auth',   "Request rigged to always fail authentication");
  is($ENV{'SWAGGER2-CORS-FAKE-AUTHENTICATE'}, 1, "'x-mojo-around-action' called");

  #Tear down test contexts
  $ENV{'SWAGGER2-CORS-FAKE-AUTHENTICATE'} = 0;

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
  is($headers->header('Access-Control-Expose-Headers'),    undef, "Access-Control-Expose-Headers undef");
  is($headers->header('Access-Control-Allow-Credentials'), undef, "Access-Control-Allow-Credentials undef");
  $body = $tx->res->body;
  is($body, "Origin 'http://fake-cors.example.com:9999' not allowed", "Origin not allowed");
  is($ENV{'SWAGGER2-CORS-FAKE-AUTHENTICATE'}, 0, "'x-mojo-around-action' not called");

  #Tear down test contexts
  $ENV{'SWAGGER2-CORS-FAKE-AUTHENTICATE'} = 0;
}

subtest "Preflight request with 'x-mojo-around-action'", \&preflightRequestxMojoAroundAction;
sub preflightRequestxMojoAroundAction {
  my ($app, $t, $ua, $tx, $headers, $json);

  $app = Mojolicious->new;
  $app->plugin(Swagger2 => {url => "data://main/x-mojo-around-action.json"});
  $t = Test::Mojo->new($app);

  #Make a OPTIONS preflight request for following DELETE-requests!
  $ua = $t->ua;
  $tx = $ua->build_tx(OPTIONS => '/api/cors-pets' => {Accept => '*/*'});
  $tx->req->headers->add('Origin' => 'http://cors.example.com:9999');
  $tx->req->headers->add('Access-Control-Request-Method' => 'DELETE');
  $tx->req->headers->add('Access-Control-Request-Headers' => 'Timezone-Offset, Sample-Source');
  $tx = $ua->start($tx);

  is($tx->res->code, 200, "Preflight response 200, CORS ok, 'x-mojo-around-action' doesn't trigger on default OPTIONS-endpoint.");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      'http://cors.example.com:9999',   "Access-Control-Allow-Origin");
  is($headers->header('Access-Control-Allow-Methods'),     'DELETE, GET, POST',              "Access-Control-Allow-Methods default overloaded");
  is($headers->header('Access-Control-Allow-Headers'),     'Timezone-Offset, Sample-Source', "Access-Control-Allow-Headers");
  is($headers->header('Access-Control-Expose-Headers'),    'Timezone-Offset, Sample-Source', "Access-Control-Expose-Headers");
  is($headers->header('Access-Control-Allow-Credentials'), 'true',                           "Access-Control-Allow-Credentials");
  is($ENV{'SWAGGER2-CORS-FAKE-AUTHENTICATE'}, 0, "'x-mojo-around-action' not called");

  #Make a failing CORS OPTIONS preflight request for following DELETE-requests. 'x-mojo-around-action' not called!
  $ua = $t->ua;
  $tx = $ua->build_tx(OPTIONS => '/api/cors-pets' => {Accept => '*/*'});
  $tx->req->headers->add('Origin' => 'http://fake-cors.example.com:9999');
  $tx->req->headers->add('Access-Control-Request-Method' => 'DELETE');
  $tx = $ua->start($tx);

  is($tx->res->code, 200, "Preflight response 200, disallowed Origin for CORS.");
  $headers = $tx->res->headers;
  is($headers->header('Access-Control-Allow-Origin'),      undef,                            "Access-Control-Allow-Origin undef");
  is($headers->header('Access-Control-Allow-Methods'),     undef,                            "Access-Control-Allow-Methods undef");
  is($headers->header('Access-Control-Allow-Headers'),     undef,                            "Access-Control-Allow-Headers undef");
  is($headers->header('Access-Control-Expose-Headers'),    undef,                            "Access-Control-Expose-Headers undef");
  is($headers->header('Access-Control-Allow-Credentials'), undef,                            "Access-Control-Allow-Credentials undef");
  is($ENV{'SWAGGER2-CORS-FAKE-AUTHENTICATE'}, 0, "'x-mojo-around-action' not called");
}

done_testing();

__DATA__
@@ x-mojo-around-action.json
{
  "swagger": "2.0",
  "basePath": "/api",
  "info": {
    "version": "1.0",
    "title": "around-action"
  },
  "x-mojo-around-action": "t::CORS::fake_authenticate",
  "x-cors": {
    "x-cors-access-control-allow-origin-list": "http://cors.example.com:9999 http://localhost:3012",
    "x-cors-access-control-allow-credentials": "true",
    "x-cors-access-control-allow-methods": "*"
  },
  "paths": {
    "/cors-pets": {
      "get": {
        "x-mojo-controller": "t::Api",
        "operationId": "corsListPets",
        "responses": {
          "200": {"description": "anything"}
        }
      },
      "post" : {
        "x-mojo-controller": "t::Api",
        "operationId" : "addPet",
        "parameters" : [
          {
            "name" : "pet",
            "schema" : { "$ref" : "#/definitions/Pet" },
            "in" : "body",
            "required": true,
            "description" : "Pet object that needs to be added to the store"
          }
        ],
        "responses" : {
          "200": {
            "description": "pet response",
            "schema": {
              "type": "array",
              "items": { "$ref": "#/definitions/Pet" }
            }
          }
        }
      },
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
  },
  "definitions" : {
    "Pet" : {
      "required" : ["name"],
      "properties" : {
        "id" : { "format" : "int64", "type" : "integer" },
        "name" : { "type" : "string" }
      }
    }
  }
}