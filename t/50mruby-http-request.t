use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use Net::EmptyPort qw(empty_port check_port);
use Test::More;
use t::Util;

plan skip_all => 'mruby support is off'
    unless server_features()->{mruby};

plan skip_all => 'curl not found'
    unless prog_exists('curl');

plan skip_all => 'plackup not found'
    unless prog_exists('plackup');

plan skip_all => 'Starlet not found'
    unless system('perl -MStarlet /dev/null > /dev/null 2>&1') == 0;

my $upstream_hostport = "127.0.0.1:@{[empty_port()]}";

sub create_upstream {
    my @args = (
        qw(plackup -s Starlet --keepalive-timeout 100 --access-log /dev/null --listen),
        $upstream_hostport,
        ASSETS_DIR . "/upstream.psgi",
    );
    spawn_server(
        argv     => \@args,
        is_ready =>  sub {
            $upstream_hostport =~ /:([0-9]+)$/s
                or die "failed to extract port number";
            check_port($1);
        },
    );
};

my $server = spawn_h2o(sub {
    my ($port, $tls_port) = @_;
    return << "EOT";
proxy.timeout.io: 1000
hosts:
  default:
    paths:
      /:
        mruby.handler: |
          Proc.new do |env|
            http_request("http://$upstream_hostport#{env["PATH_INFO"]}#{env["QUERY_STRING"]}", {
              method: env["REQUEST_METHOD"],
              body: env["rack.input"],
            }).join
          end
      /as_str:
        mruby.handler: |
          Proc.new do |env|
            [200, {}, [http_request("http://$upstream_hostport/index.txt").join[2].join]]
          end
      /cl:
        mruby.handler: |
          Proc.new do |env|
            if !/^\\/([0-9]+)/.match(env["PATH_INFO"])
              raise "failed to parse PATH_INFO"
            end
            cl = \$1
            body = ["abc", "def", "ghi", "jkl", "mno"]
            if \$'.length != 0
              class T
                def initialize(a)
                  \@a = a
                end
                def each(&b)
                  \@a.each(&b)
                end
              end
              body = T.new(body)
            end
            [200, {"content-length" => cl}, body]
          end
      /esi:
        mruby.handler: |
          class ESIResponse
            def initialize(input)
              \@parts = input.split /(<esi:include +src=".*?" *\\/>)/
              \@parts.each_with_index do |part, index|
                if /^<esi:include +src=" *(.*?) *"/.match(part)
                  \@parts[index] = http_request("http://$upstream_hostport/#{\$1}")
                end
              end
            end
            def each(&block)
              \@parts.each do |part|
                if part.kind_of? String
                  block.call(part)
                else
                  part.join[2].each(&block)
                end
              end
            end
          end
          Proc.new do |env|
            resp = http_request("http://$upstream_hostport/esi.html").join
            resp[2] = ESIResponse.new(resp[2].join)
            resp
          end
      /fast-path-partial:
        mruby.handler: |
          Proc.new do |env|
            resp = http_request("http://$upstream_hostport/streaming-body").join
            resp[2].each do |x|
              break
            end
            resp
          end
EOT
});

sub doit {
    my ($proto, $port) = @_;
    my $curl_cmd = 'curl --insecure --silent --dump-header /dev/stderr';
    subtest "connection-error" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/index.txt");
        like $headers, qr{HTTP/1\.1 500 }is;
    };
    my $upstream = create_upstream();
    subtest "get" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/index.txt");
        like $headers, qr{HTTP/1\.1 200 }is;
        is $body, "hello\n";
    };
    subtest "post" => sub {
        my ($headers, $body) = run_prog("$curl_cmd --data 'hello world' $proto://127.0.0.1:$port/echo");
        like $headers, qr{HTTP/1\.1 200 }is;
        is $body, 'hello world';
    };
    subtest "slow-chunked" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/streaming-body");
        like $headers, qr{HTTP/1\.1 200 }is;
        is $body, (join "", 1..30);
    };
    subtest "as_str" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/as_str/");
        like $headers, qr{HTTP/1\.1 200 }is;
        is $body, "hello\n";
    };
    subtest "content-length" => sub {
        subtest "non-chunked" => sub {
            for my $i (0..15) {
                subtest "cl=$i" => sub {
                    my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/cl/$i");
                    like $headers, qr{^HTTP/1\.1 200 .*\ncontent-length:\s*$i\r}is;
                    is $body, substr "abcdefghijklmno", 0, $i;
                }
            };
            for my $i (16..30) {
                subtest "cl=$i" => sub {
                    my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/cl/$i");
                    like $headers, qr{^HTTP/1\.1 200 .*\ncontent-length:\s*15\r}is;
                    is $body, "abcdefghijklmno";
                }
            };
        };
        subtest "chunked" => sub {
            for my $i (0..30) {
                subtest "cl=$i" => sub {
                    my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/cl/$i/chunked");
                    like $headers, qr{^HTTP/1\.1 200 .*\ncontent-length:\s*$i\r}is;
                    is $body, substr "abcdefghijklmno", 0, $i;
                }
            };
        };
    };
    subtest "esi" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/esi/");
        like $headers, qr{HTTP/1\.1 200 }is;
        is $body, "Hello to the world, from H2O!\n";
    };
    subtest "fast-path-partial" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/fast-path-partial/");
        like $headers, qr{HTTP/1\.1 200 }is;
        is $body, join "", 2..30;
    };
}

subtest "http/1" => sub {
    doit("http", $server->{port});
};

subtest "https/1" => sub {
    doit("https", $server->{tls_port});
};

subtest "http2" => sub {
    plan skip_all => "curl does not support HTTP/2"
        unless curl_supports_http2();
    doit("https", $server->{tls_port}, "--http2");
};

done_testing();