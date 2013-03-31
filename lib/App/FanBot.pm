package App::FanBot;
use strict;
use warnings;
use utf8;
use Class::Accessor::Lite (
    ro => [
        'my_id', 
        'is_background',
        '_cred','_search_keywords', '_exclude_users', '_exclude_patterns', '_exclude_urls',
        '_exclude_clients', 'search_interval',  'app_name', 'twitty',      '_official_ids',
    ],
);

our $VERSION = '0.01';

use AnyEvent::Twitter;
use Config::Pit;
use Encode;
use File::Stamped;
use Log::Minimal;
use FindBin;
use File::Basename;
use List::MoreUtils qw(any all);
use List::Util qw(max);

sub new {
    my ($class, $option_href) = @_;
    my $is_background = defined $option_href->{background} ? $option_href->{background} : 0;
    my $self = {
        is_background => $is_background,
        _exclude_urls => [ # amazon とかに流そうとしてるやつは除外
            'amazon.co.jp',
            'amzn.to',
            'eventernote.com',
            'za4.ch',
            'books.rakuten.co.jp',
            'botchan.biz',
        ],
        _exclude_clients => [ # 定期ポストに使っているクライアント
            'twittbot.net',
            'twiroboJP',
            'makebot.sh',
            'The_AutoTweet',
            'BotMaker',
            'ツイ助。',
            '劣化コピー',
            'なうぷれTunes',
            'LikeBoard',
            'SongsInfo on iOS',
            'TWTunes',
            'RakutenSuperRecommend',
            'JoyHack',
            'これ聴いてるんだからねっ！',
            'wktk',
            'TweetMag1c MusicEdition',
            'Amzn777',
        ],
        _exclude_users => [
        ],
        _official_ids => [
        ],
        search_interval => 120,
        app_name        => $option_href->{app_name},
    };
    bless $self, $class;
    $self->_init_credential();
    $self->{twitty} = AnyEvent::Twitter->new($self->credential);
    return $self;
}

sub _init_credential {
    my ($self) = @_;
    my $app_name = $self->app_name;
    die "app name is not set" if ( !defined $app_name );
    my $config = pit_get($app_name, require => {
        consumer_key    => 'consumer_key',
        consumer_secret => 'consumer_secret',
        token           => 'token',
        token_secret    => 'token_secret',
    });

    $self->{_cred} = {
        username        => $app_name,
        consumer_key    => $config->{consumer_key},
        consumer_secret => $config->{consumer_secret},
        token           => $config->{token},
        token_secret    => $config->{token_secret},
    };
}

sub official_ids {
    my ($self) = @_;
    return @{ $self->_official_ids };
}

sub credential {
    my ($self) = @_;
    return %{ $self->_cred };
}

sub search_keywords {
    my ($self) = @_;
    return @{ $self->_search_keywords };
}

sub exclude_users {
    my ($self) = @_;
    return @{ $self->_exclude_users };
}

sub exclude_patterns {
    my ($self) = @_;
    return @{ $self->_exclude_patterns };
}

sub exclude_urls {
    my ($self) = @_;
    return @{ $self->_exclude_urls };
}

sub exclude_clients {
    my ($self) = @_;
    return @{ $self->_exclude_clients };
}

sub is_official {
    my ($self, $tweet) = @_;
    return any { $_ eq $tweet->{user}->{id} } $self->official_ids;
}

# 自分へのメンションかどうか
sub is_mention_to_me {
    my ($self, $tweet) = @_;
    return defined $tweet->{in_reply_to_user_id} && $tweet->{in_reply_to_user_id} eq $self->my_id;
}

# search を投げるためのタイマーを返す
sub search_timer {
    my ($self) = @_;
    return AnyEvent->timer(
        after    => 5,# latest_id_update を待つため
        interval => $self->search_interval || 120,
        cb       => sub {
            return if ( !defined $self->{since_id} );
            for my $keyword ( $self->search_keywords ) {
                $self->search_and_rt($keyword);
            }
        },
    );
}

# 公式 RT を投げる
sub do_rt {
    my ($self, $id, $user, $text) = @_;
    if( $ENV{BOT_DEBUG} ) {
        print encode_utf8("\@$user : $text\n");
    }
    else {
        $self->twitty->post("statuses/retweet/$id", {
        }, sub {
            my ($header, $response, $reason, $error) = @_;
            if( defined $error ) {
                my $msg  = $error->{errors};
                $self->logging("$msg", 'warn');
                return;
            }

            $self->logging("retweeted: $user : $text\n");
        });
    }
}

# 単発の tweet を投げます
sub simple_tweet {
    my ($self, $tweet) = @_;

    my $cv = AnyEvent->condvar;
    $cv->begin;
    $self->twitty->post('statuses/update', {
        status => $tweet,
    }, sub {
        my ($header, $response, $reason, $error) = @_;
        if( defined $error ) {
            my $code = $error->{errors}->[0]->{code};
            my $msg  = $error->{errors}->[0]->{message};
            $self->logging("$code : $msg", 'warn');
        }
        $cv->end;
    });
    $cv->recv;
}

sub search_and_rt {
    my ($self, $keyword) = @_;
    $self->twitty->get('search/tweets', {
        q           => $keyword,
        count       => 100,
        result_type => 'recent',
        %{ $self->{since_id} || {} },
    }, sub {
        my ($header, $response, $reason, $error) = @_;
        if( defined $error && $error->{errors} ) {
            my $code = $error->{errors}->[0]->{code};
            my $msg  = $error->{errors}->[0]->{message};
            $self->logging("$code : $msg", 'warn');
            return;
        }
        my @tweets = @{ $response->{statuses} || [] };
        for my $tweet ( sort { $a->{id} <=> $b->{id} } @tweets ) {
            my $user   = $tweet->{user}->{screen_name};
            my $text   = ($tweet->{text} || '');
            my $id     = $tweet->{id};
            my $client = $tweet->{source};

            next if ( any { $_ eq $id          } @{ $self->{tweeted} || [] } );
            next if ( any { $_ eq $user        } $self->exclude_users );
            next if ( any { $text   =~ qr/$_/i } $self->exclude_patterns );
            next if ( any { $client =~ qr/$_/i } $self->exclude_clients );
            next if ( $self->is_exclude_url(@{ $tweet->{entities}->{urls} || [] } ) );

            $self->do_rt($id, $user, $text);
            push @{ $self->{tweeted} }, $id;
        }
        $self->{searched}->{$keyword} = 1;
        $self->reflesh_searched();
    });
}

# 検索時に使うための最新の ID をセットする
sub update_latest_since_id {
    my ($self) = @_;
    $self->twitty->get('statuses/home_timeline', {
        count => '1',
    }, sub {
        my ($header, $response, $reason, $error) = @_;
        if( defined $error ) {
            my $code = $error->{errors}->[0]->{code};
            my $msg  = $error->{errors}->[0]->{message};
            $self->logging("$code : $msg", 'warn');
            return;
        }
        my $id = $response->[0]->{id};
        if( defined $id) {
            $id = max($id, $self->{since_id}->{since_id}) if ( defined $self->{since_id} );
            $self->{since_id} = { since_id => $id };
        }
    });
}

# 全部のキーワードに対して検索を投げ終わったら、since_id を更新して tweet 済みのリストを消す
sub reflesh_searched {
    my ($self) = @_;
    if( all {  $self->{searched}->{$_} } $self->search_keywords ) {
        my $max_id = max($self->{since_id}->{since_id}, @{ $self->{tweeted} });
        $self->{since_id} = { since_id => $max_id };
        $self->{tweeted}  = [];
        $self->{searched} = {};
    }
}

sub is_exclude_url {
    my ($self, @urls) = @_;
    for my $url ( @urls ) {
        next if ( !defined $url->{expanded_url} );
        return 1 if ( any { $url->{expanded_url} =~ qr/$_/ } $self->exclude_urls );
    }
    return;
}

sub logging {
    my ($self, $message, $severity) = @_;

    my $fh = File::Stamped->new(pattern => "$FindBin::RealBin/../milkian_bot.%Y%m%d.log");
    local $Log::Minimal::PRINT = sub {
        my ($time, $type, $message, $trace) = @_;
        my $app = basename($0);
        my $encoded_message = encode_utf8("$time [$app:$$] $type $message at $trace\n");
        if( $self->is_background ) {
            print {$fh} $encoded_message;
        }
        else {
            warn $encoded_message;
        }
    };

    $severity = 'info' if ( !defined $severity );
    if( $severity eq 'info' ) {
        infof $message;
    }
    elsif ( $severity eq 'warn' || $severity eq 'warning' ) {
        warnf $message;
    }
    elsif( $severity eq 'crit' || $severity eq 'critical' ) {
        critf $message;
    }
    else {
        debugf $message;
    }

}

1;
