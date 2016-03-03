use Test::More;
use Swagger2;

my $swagger = Swagger2->new('t/data/id-as-root.json');
eval {
    $swagger = $swagger->expand; #Fetch all JSON-Schema references
};
ok($@, "Reference resolving died as expected");
ok($@ =~ /id-as-root\/defs.json contains an abnormal 'id'. Are you sure you haven't manually defined 'id' in that file\?/, "and produced a helpful suggestion");

done_testing;
