package t::CORS;

=head1 IN THIS FILE

We implement test subroutines to test CORS operations.

=cut

=head2 origin_whitelist

Used to test the "x-cors-access-control-allow-origin-list" CORS option.

=cut

sub origin_whitelist {
  my ($origin) = @_;
  return $origin if($origin && $origin =~ /example/);
  return undef;
}

1; #Make compiler happy!