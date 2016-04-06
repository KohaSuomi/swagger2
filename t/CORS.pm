package t::CORS;

=head1 IN THIS FILE

We implement test subroutines to test CORS operations.

=cut

=head2 origin_whitelist

Used to test the "x-cors-access-control-allow-origin-list" CORS option.

@param {Mojolicious::Controller} $c
@param {String} $origin, the origin to accept or deny.
@returns {String or undef}, The $origin if it is accepted or undef.

=cut

use Scalar::Util qw(blessed);

sub origin_whitelist {
  my ($c, $origin) = @_;
  my @cc = caller(0);
  die $cc[3]."($c, $origin):> \$c '$c' is not a Mojolicious::Controller!" unless(blessed($c) && $c->isa('Mojolicious::Controller'));
  return $origin if($origin && $origin =~ /example/);
  return undef;
}

1; #Make compiler happy!