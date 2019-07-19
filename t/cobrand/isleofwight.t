use CGI::Simple;
use DateTime;
use FixMyStreet::TestMech;
use Open311;

ok( my $mech = FixMyStreet::TestMech->new, 'Created mech object' );

my $params = {
    send_method => 'Open311',
    send_comments => 1,
    api_key => 'KEY',
    endpoint => 'endpoint',
    jurisdiction => 'home',
};
my $isleofwight = $mech->create_body_ok(2636, 'Isle of Wight Council', $params);
$mech->create_contact_ok(
    body_id => $isleofwight->id,
    category => 'Potholes',
    email => 'pothole@example.org',
);

my $user = $mech->create_user_ok('user@example.org');

my @reports = $mech->create_problems_for_body(1, $isleofwight->id, 'An Isle of wight report', {
    confirmed => '2019-05-25 09:00',
    lastupdate => '2019-05-25 09:00',
    latitude => 50.7108,
    longitude => -1.29573,
    user => $user
});

subtest "check clicking all reports link" => sub {
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'isleofwight',
    }, sub {
        $mech->get_ok('/');
        $mech->follow_link_ok({ text => 'All reports' });
    };

    $mech->content_contains("An Isle of wight report", "Isle of Wight report there");
    $mech->content_contains("Island Roads", "is still on cobrand");
};

subtest "only original reporter can comment" => sub {
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'isleofwight',
    }, sub {
        $mech->get_ok('/report/' . $reports[0]->id);
        $mech->content_contains('Only the original reporter may leave updates');

        $mech->log_in_ok('user@example.org');
        $mech->get_ok('/report/' . $reports[0]->id);
        $mech->content_lacks('Only the original reporter may leave updates');
    };
};

subtest "fixing passes along the correct message" => sub {
    FixMyStreet::override_config {
        MAPIT_URL => 'http://mapit.uk/',
        ALLOWED_COBRANDS => 'isleofwight',
    }, sub {
        my $test_res = HTTP::Response->new();
        $test_res->code(200);
        $test_res->message('OK');
        $test_res->content('<?xml version="1.0" encoding="utf-8"?><service_request_updates><request_update><update_id>248</update_id></request_update></service_request_updates>');

        my $o = Open311->new(
            fixmystreet_body => $isleofwight,
            test_mode => 1,
            test_get_returns => { 'servicerequestupdates.xml' => $test_res },
        );

        my ($p) = $mech->create_problems_for_body(1, $isleofwight->id, 'Title', { external_id => 1 });

        my $c = FixMyStreet::App->model('DB::Comment')->create({
            problem => $p, user => $p->user, anonymous => 't', text => 'Update text',
            problem_state => 'fixed - council', state => 'confirmed', mark_fixed => 0,
            confirmed => DateTime->now(),
        });

        my $id = $o->post_service_request_update($c);
        is $id, 248, 'correct update ID returned';
        my $cgi = CGI::Simple->new($o->test_req_used->content);
        like $cgi->param('description'), qr/^FMS-Update:/, 'FMS update prefix included';
        unlike $cgi->param('description'), qr/The customer indicated that this issue had been fixed/, 'No fixed message included';

        $c = $mech->create_comment_for_problem($p, $p->user, 'Name', 'Update text', 'f', 'confirmed', 'fixed - user', { confirmed => \'current_timestamp' });
        $c->discard_changes; # Otherwise cannot set_nanosecond

        $id = $o->post_service_request_update($c);
        is $id, 248, 'correct update ID returned';
        $cgi = CGI::Simple->new($o->test_req_used->content);
        like $cgi->param('description'), qr/^FMS-Update: \[The customer indicated that this issue had been fixed/, 'Fixed message included';
    };
};

done_testing();