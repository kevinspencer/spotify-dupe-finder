#!/usr/bin/env perl

use YAML::Tiny;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use File::Path qw(make_path);
use IO::Socket::INET;
use MIME::Base64 qw(encode_base64);
use strict;
use warnings;
use Getopt::Long;

my $dry_run = 0;
GetOptions('dry-run' => \$dry_run);

my $config_file  = 'conf/config.yaml';
my $cache_dir    = 'cache';
my $token_cache  = "$cache_dir/spotify_token.json";
my $tracks_cache = "$cache_dir/spotify_liked.json";

my $yaml = YAML::Tiny->read($config_file)
    or die "Cannot read config: " . YAML::Tiny->errstr;
my $config = $yaml->[0];

my $ua = LWP::UserAgent->new();

binmode(STDOUT, ':encoding(UTF-8)');

make_path($cache_dir);

my @tracks;
if (-f $tracks_cache && prompt_use_cache($tracks_cache)) {
    @tracks = @{ load_cache($tracks_cache) };
    print "Loaded " . scalar(@tracks) . " tracks from cache.\n";
} else {
    print "Fetching Spotify liked tracks...\n";
    my $access_token = get_spotify_token($config, $token_cache);
    @tracks = fetch_spotify_tracks($ua, $access_token);
    print "Fetched " . scalar(@tracks) . " liked tracks.\n";
    write_cache($tracks_cache, \@tracks);
    print "Cache written to $tracks_cache\n";
}

my %by_id;
my %by_key;

for my $track (@tracks) {
    push @{ $by_id{$track->{track_id}} }, $track;
    my $key = normalize_key($track->{artist}, $track->{title_clean});
    push @{ $by_key{$key} }, $track;
}

# Exact dupes: same track_id liked more than once
my @exact_dupe_ids = grep { scalar(@{ $by_id{$_} }) > 1 } keys %by_id;

# Fuzzy dupes: same normalized artist|title, different track_ids
my @fuzzy_dupe_keys = grep {
    my @group = @{ $by_key{$_} };
    if (scalar(@group) < 2) {
        0;
    } else {
        my %ids = map { $_->{track_id} => 1 } @group;
        scalar(keys %ids) > 1;
    }
} keys %by_key;

my $total_exact = scalar(@exact_dupe_ids);
my $total_fuzzy = scalar(@fuzzy_dupe_keys);

print "\n";
print "=" x 60 . "\n";
print "Duplicate scan results\n";
print "=" x 60 . "\n";
print "  Exact duplicates (same track ID liked twice): $total_exact\n";
print "  Fuzzy duplicates (same song, different versions): $total_fuzzy\n";
print "=" x 60 . "\n";

if ($total_exact > 0) {
    print "\n--- Exact Duplicates (same track ID) ---\n\n";
    for my $id (sort @exact_dupe_ids) {
        my $t = $by_id{$id}[0];
        printf "  %s - %s\n", $t->{artist}, $t->{title};
        printf "  track_id: %s  (liked %d times)\n\n", $id, scalar(@{ $by_id{$id} });
    }
}

if ($total_fuzzy > 0) {
    print "\n--- Fuzzy Duplicates (same song, different versions) ---\n\n";

    my @sorted_keys = sort {
        $by_key{$a}[0]{artist} cmp $by_key{$b}[0]{artist}
            || $by_key{$a}[0]{title_clean} cmp $by_key{$b}[0]{title_clean}
    } @fuzzy_dupe_keys;

    for my $key (@sorted_keys) {
        my @group = sort {
            (($a->{title} eq $a->{title_clean}) ? 0 : 1) <=> (($b->{title} eq $b->{title_clean}) ? 0 : 1)
                || $a->{added_at} cmp $b->{added_at}
        } @{ $by_key{$key} };
        my $first = $group[0];
        printf "  %s - %s\n", $first->{artist}, $first->{title_clean};
        for my $i (0 .. $#group) {
            my $t     = $group[$i];
            my $label = $i == 0 ? '[KEEP]' : '[DUPE]';
            my $date  = substr($t->{added_at}, 0, 10);
            printf "    %s  %-50s  added %s  id:%s\n",
                $label, qq("$t->{title}"), $date, $t->{track_id};
        }
        print "\n";
    }
}

if ($total_exact == 0 && $total_fuzzy == 0) {
    print "\nNo duplicates found.\n";
}

# Collect all DUPE track IDs (second+ entry in each fuzzy group, plus exact dupes beyond the first)
my @dupe_ids;

for my $id (@exact_dupe_ids) {
    my @entries = @{ $by_id{$id} };
    # Keep one, remove the rest (by count of extras)
    for (2 .. scalar(@entries)) {
        push @dupe_ids, $id;
    }
}

for my $key (@fuzzy_dupe_keys) {
    my @group = sort {
        (($a->{title} eq $a->{title_clean}) ? 0 : 1) <=> (($b->{title} eq $b->{title_clean}) ? 0 : 1)
            || $a->{added_at} cmp $b->{added_at}
    } @{ $by_key{$key} };
    for my $i (1 .. $#group) {
        push @dupe_ids, $group[$i]{track_id};
    }
}

if (@dupe_ids) {
    print "\n" . "=" x 60 . "\n";
    printf "Found %d track(s) to remove.\n", scalar(@dupe_ids);

    if ($dry_run) {
        print "\n[DRY RUN] The following Spotify API calls would be made:\n\n";
        my @remaining = @dupe_ids;
        my $batch_num = 1;
        while (@remaining) {
            my @batch = splice(@remaining, 0, 50);
            printf "  DELETE https://api.spotify.com/v1/me/tracks  (batch %d, %d track(s))\n",
                $batch_num++, scalar(@batch);
            printf "    ids: %s\n", join(', ', @batch);
        }
        print "\n[DRY RUN] No tracks were removed.\n";
    } else {
        print "Would you like to remove the [DUPE] tracks from your Spotify library? [y/n] ";
        chomp(my $answer = <STDIN>);
        if (lc($answer) eq 'y') {
            print "Are you sure? This cannot be undone. Type YES to confirm: ";
            chomp(my $confirm = <STDIN>);
            if ($confirm eq 'YES') {
                my $access_token = get_spotify_token($config, $token_cache);
                remove_spotify_tracks($ua, $access_token, \@dupe_ids);
            } else {
                print "Aborted.\n";
            }
        } else {
            print "No tracks removed.\n";
        }
    }
}

sub remove_spotify_tracks {
    my ($ua, $access_token, $ids) = @_;

    my @batches;
    my @remaining = @$ids;
    while (@remaining) {
        push @batches, [splice(@remaining, 0, 50)];
    }

    printf "Removing %d track(s) in %d batch(es)...\n", scalar(@$ids), scalar(@batches);

    my $removed = 0;
    for my $batch (@batches) {
        my $response = $ua->request(
            HTTP::Request->new(
                'DELETE',
                'https://api.spotify.com/v1/me/tracks',
                [
                    Authorization  => "Bearer $access_token",
                    'Content-Type' => 'application/json',
                ],
                encode_json({ ids => $batch }),
            )
        );
        if ($response->is_success()) {
            $removed += scalar(@$batch);
            printf "  Removed %d / %d\n", $removed, scalar(@$ids);
        } else {
            printf "  Batch failed: %s\n", $response->status_line();
        }
    }

    print "Done. $removed track(s) removed from your library.\n";
}

sub fetch_spotify_tracks {
    my ($ua, $access_token) = @_;

    my @tracks;
    my $url = 'https://api.spotify.com/v1/me/tracks?limit=50';

    while ($url) {
        my $response = $ua->get($url, Authorization => "Bearer $access_token");
        die "Spotify API error: " . $response->status_line()
            unless $response->is_success();

        my $data = decode_json($response->content());
        my $from = scalar(@tracks) + 1;
        my $to   = scalar(@tracks) + scalar(@{ $data->{items} });
        print "Fetching tracks $from - $to of $data->{total}\n";

        for my $item (@{ $data->{items} }) {
            my $track = $item->{track};
            push @tracks, {
                track_id    => $track->{id},
                artist      => $track->{artists}[0]{name},
                title       => $track->{name},
                title_clean => clean_spotify_title($track->{name}),
                added_at    => $item->{added_at},
            };
        }

        $url = $data->{next};
    }

    return @tracks;
}

sub clean_spotify_title {
    my ($title) = @_;
    $title =~ s{\s*[-;/,]\s*(?:\d{4}\s+)?(?:(?:Digital\s+)?Remaster(?:ed)?|Digital\s+Master|Edit)(?:\s+\d{4})?(?:\s+Version)?\s*$}{}i;
    $title =~ s{\s*\((?:\d{4}\s+)?(?:Digital\s+)?Remaster(?:ed)?(?:\s+\d{4})?(?:\s+Version)?\s*\)\s*$}{}i;
    $title =~ s{\s*-\s*(?:Original\s+)?(?:\d+["']\s+)?(?:Single\s+)?(?:Version|Edit|Mix)\s*$}{}i;
    $title =~ s/\s+$//;
    return $title;
}

sub normalize_key {
    my ($artist, $title) = @_;
    my $key = lc("$artist|$title");
    $key =~ s/[^\w\s|]//g;
    $key =~ s/\s+/ /g;
    $key =~ s/^\s+|\s+$//g;
    return $key;
}

sub prompt_use_cache {
    my ($cache_file) = @_;
    my $mtime   = (stat($cache_file))[9];
    my $age     = time() - $mtime;
    my $age_str = $age < 3600 ? int($age / 60) . " minutes" : int($age / 3600) . " hours";
    print "Cache exists (age: $age_str). Use cached data? [y/n] ";
    chomp(my $answer = <STDIN>);
    return lc($answer) eq 'y';
}

sub load_cache {
    my ($cache_file) = @_;
    open my $fh, '<', $cache_file or die "Cannot read cache $cache_file: $!";
    my $json = do { local $/; <$fh> };
    close $fh;
    return decode_json($json);
}

sub write_cache {
    my ($cache_file, $data) = @_;
    open my $fh, '>', $cache_file or die "Cannot write cache $cache_file: $!";
    print $fh encode_json($data);
    close $fh;
}

sub get_spotify_token {
    my ($config, $token_cache) = @_;

    if (-f $token_cache) {
        open my $fh, '<', $token_cache or die "Cannot read token cache: $!";
        my $json = do { local $/; <$fh> };
        close $fh;
        my $token_data = decode_json($json);

        if ($token_data->{expires_at} > time() + 60) {
            print "Using cached Spotify token.\n";
            return $token_data->{access_token};
        }

        if ($token_data->{refresh_token}) {
            print "Refreshing Spotify token...\n";
            return refresh_spotify_token($config, $token_data->{refresh_token}, $token_cache);
        }
    }

    return do_spotify_oauth($config, $token_cache);
}

sub do_spotify_oauth {
    my ($config, $token_cache) = @_;

    my $client_id    = $config->{spotify}{client_id};
    my $redirect_uri = $config->{spotify}{redirect_uri};
    my $scope        = 'user-library-read user-library-modify';

    my $auth_url = "https://accounts.spotify.com/authorize"
                 . "?client_id=$client_id"
                 . "&response_type=code"
                 . "&redirect_uri=$redirect_uri"
                 . "&scope=$scope";

    print "Opening Spotify authorization in browser...\n";
    print "If it doesn't open automatically, visit:\n$auth_url\n\n";
    system('open', $auth_url);

    my $code = capture_oauth_callback();
    die "No authorization code received" unless $code;

    return exchange_code_for_token($config, $code, $token_cache);
}

sub capture_oauth_callback {
    my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 8888,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Cannot start callback server on port 8888: $!";

    print "Waiting for Spotify authorization callback...\n";

    my $client  = $server->accept();
    my $request = '';
    while (my $line = <$client>) {
        $request .= $line;
        last if $line =~ /^\r?\n$/;
    }

    my ($code) = $request =~ /GET \/callback\?code=([^\s&]+)/;

    print $client "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n";
    print $client "<html><body><h1>Authorization successful! You can close this tab.</h1></body></html>\r\n";

    close $client;
    close $server;

    return $code;
}

sub exchange_code_for_token {
    my ($config, $code, $token_cache) = @_;

    my $client_id     = $config->{spotify}{client_id};
    my $client_secret = $config->{spotify}{client_secret};
    my $redirect_uri  = $config->{spotify}{redirect_uri};
    my $credentials   = encode_base64("$client_id:$client_secret", '');

    my $response = $ua->post(
        'https://accounts.spotify.com/api/token',
        Authorization => "Basic $credentials",
        Content => [
            grant_type   => 'authorization_code',
            code         => $code,
            redirect_uri => $redirect_uri,
        ],
    );

    die "Token exchange failed: " . $response->status_line()
        unless $response->is_success();

    my $token_data = decode_json($response->content());
    save_token($token_data, $token_cache);

    return $token_data->{access_token};
}

sub refresh_spotify_token {
    my ($config, $refresh_token, $token_cache) = @_;

    my $client_id     = $config->{spotify}{client_id};
    my $client_secret = $config->{spotify}{client_secret};
    my $credentials   = encode_base64("$client_id:$client_secret", '');

    my $response = $ua->post(
        'https://accounts.spotify.com/api/token',
        Authorization => "Basic $credentials",
        Content => [
            grant_type    => 'refresh_token',
            refresh_token => $refresh_token,
        ],
    );

    die "Token refresh failed: " . $response->status_line()
        unless $response->is_success();

    my $token_data = decode_json($response->content());
    $token_data->{refresh_token} //= $refresh_token;
    save_token($token_data, $token_cache);

    return $token_data->{access_token};
}

sub save_token {
    my ($token_data, $token_cache) = @_;
    $token_data->{expires_at} = time() + $token_data->{expires_in};
    open my $fh, '>', $token_cache or die "Cannot write token cache: $!";
    print $fh encode_json($token_data);
    close $fh;
}
