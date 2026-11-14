#!/usr/bin/env perl
#
# 有些人用perl处理数据，有些人用perl玩烂梗，我们都有美好的未来
# Author: 玩肥鱼、DeepSeek
#
# deepseek（已深度思考0.01秒）：饱喂鱼娘 查看活动〉
#
# 标记示例:
#   <<<{"barrage":"if","pageNum":1,"pageSize":10,"sort":0,"filter":["🥺","😅"]}>>>
#
# 处理逻辑参考 .github/workflows/update.yml，并按需要扩展:
#   1. 用标记里的参数 POST JSON 到接口（只取一页）;
#   2. 取 data.list 中每条的 barrage 字段，折叠换行、去首尾空白，丢弃空条目;
#   3. 按 filter 做字面筛选（包含任一项即保留）;
#   4. filter 非空时按 $DEFAULT_MAX_PAGESIZE 条/页抓取，最终仍只保留 pageSize 条;
#   5. 对保留条目转义 ~，条目之间空一行（join "\n\n"）。
#
use strict;
use warnings;
use utf8;

use Encode qw(decode encode FB_CROAK);
use JSON::PP;
use Getopt::Long qw(GetOptions);
use File::Temp qw(tempfile);
use File::Basename qw(dirname);
use Cwd qw(abs_path);

use open ':std', ':encoding(UTF-8)';

my $DEFAULT_API          = 'https://api.hguofichp.cn/machine/pageSearch';
my $DEFAULT_TIMEOUT      = 30;
my $DEFAULT_RETRY        = 2;
my $DEFAULT_MAX_PAGESIZE = 500;

my ($api, $timeout, $retry, $to_stdout, $help) =
    ($DEFAULT_API, $DEFAULT_TIMEOUT, $DEFAULT_RETRY, 0, 0);

GetOptions(
    'api=s'     => \$api,
    'timeout=i' => \$timeout,
    'retry=i'   => \$retry,
    'stdout'    => \$to_stdout,
    'help|h'    => \$help,
) or usage(1);

usage(0) if $help;
usage(1) unless @ARGV == 1;

my $input = shift @ARGV;
fail("错误：文件不存在或不是普通文件：$input\n") unless -f $input;

my $path = abs_path($input);
fail("错误：无法解析路径：$input\n") unless defined $path;

$timeout = 1 if $timeout < 1;
$retry   = 0 if $retry < 0;

my $doc   = read_text($path);
my @marks = find_marks($doc);

if (!@marks) {
    warn "未找到 <<<...>>> 标记，文件未修改：$path\n";
    exit 0;
}

my %cache;   # 相同请求只发一次
my $out   = '';
my $last  = 0;
my $count = 0;

for my $mark (@marks) {
    my $line  = 1 + (substr($doc, 0, $mark->{start}) =~ tr/\n//);
    my $where = "$path 第 $line 行";
    my $text  = render_mark($mark->{content}, $where, \%cache);

    $out .= substr($doc, $last, $mark->{start} - $last);
    $out .= $text;
    $last = $mark->{end};
    $count++;
}
$out .= substr($doc, $last);

if ($to_stdout) {
    print $out;
}
else {
    write_text_atomic($path, $out);
    warn "已替换 $count 个标记：$path\n";
}

exit 0;

# ---------------------------------------------------------------- 文件读写

sub read_text {
    my ($file) = @_;

    open(my $fh, '<:raw', $file)
        or fail("错误：无法读取 $file：$!\n");
    my $bytes;
    { local $/; $bytes = <$fh>; }
    close($fh)
        or fail("错误：读取 $file 失败：$!\n");

    $bytes = '' unless defined $bytes;

    my $text = eval { decode('UTF-8', $bytes, FB_CROAK) };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        fail("错误：$file 不是合法的 UTF-8 文本（$err）\n");
    }

    return $text;
}

sub write_text_atomic {
    my ($file, $text) = @_;

    my $dir = dirname($file);
    my ($fh, $tmp) = tempfile('.expand_md-XXXXXX', DIR => $dir, UNLINK => 0);

    my $ok = eval {
        binmode($fh);
        print {$fh} encode('UTF-8', $text)
            or die "错误：写入临时文件失败：$!\n";
        close($fh)
            or die "错误：关闭临时文件失败：$!\n";

        my $mode = (stat($file))[2];
        chmod($mode & 07777, $tmp) if defined $mode;

        rename($tmp, $file)
            or die "错误：替换 $file 失败：$!\n";
        1;
    };

    if (!$ok) {
        my $err = $@;
        unlink $tmp;
        fail($err);
    }
}

# ---------------------------------------------------------------- 标记处理

sub find_marks {
    my ($text) = @_;

    my @marks;
    while ($text =~ /<<<(.*?)>>>/sg) {
        push @marks, {
            start   => $-[0],
            end     => $+[0],
            content => $1,
        };
    }

    return @marks;
}

sub parse_params {
    my ($content, $where) = @_;

    my $json = $content;
    $json =~ s/^\s+|\s+$//g;

    my $params = eval {
        JSON::PP->new->utf8->decode(encode('UTF-8', $json));
    };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        fail("$where：标记内容不是合法 JSON（$err）\n");
    }

    fail("$where：标记内容必须是 JSON 对象\n")
        unless ref($params) eq 'HASH';

    fail("$where：缺少必填字段 barrage\n")
        unless exists $params->{barrage};

    fail("$where：barrage 必须是字符串\n")
        unless defined($params->{barrage}) && !ref($params->{barrage});

    for my $key (qw(pageNum pageSize sort)) {
        next unless exists $params->{$key};
        my $value = $params->{$key};
        fail("$where：$key 必须是整数\n")
            unless defined($value) && !ref($value) && $value =~ /\A-?\d+\z/;
    }

    fail("$where：pageNum 必须为正整数\n")
        if exists $params->{pageNum} && $params->{pageNum} + 0 < 1;

    fail("$where：pageSize 必须为正整数\n")
        if exists $params->{pageSize} && $params->{pageSize} + 0 < 1;

    my $filter = [];
    if (exists $params->{filter}) {
        my $raw = $params->{filter};
        fail("$where：filter 必须是字符串数组\n")
            unless ref($raw) eq 'ARRAY';

        my $index = 0;
        for my $item (@$raw) {
            $index++;
            fail("$where：filter 第 $index 项必须是字符串\n")
                unless defined($item) && !ref($item);
            push @$filter, "$item";
        }
    }

    return {
        request => {
            barrage  => $params->{barrage},
            pageNum  => exists $params->{pageNum}  ? $params->{pageNum}  + 0 : 1,
            pageSize => exists $params->{pageSize} ? $params->{pageSize} + 0 : 10,
            sort     => exists $params->{sort}     ? $params->{sort}     + 0 : 0,
        },
        filter => $filter,
    };
}

sub render_mark {
    my ($content, $where, $cache) = @_;

    my $spec = parse_params($content, $where);
    my $kept = collect_items($spec, $where, $cache);

    my @escaped;
    for my $text (@$kept) {
        my $line = $text;
        $line =~ s/~/\\~/g;
        push @escaped, $line;
    }

    return join("\n\n", @escaped);
}

sub keep_item {
    my ($text, $filter) = @_;

    return 1 unless @$filter;

    for my $needle (@$filter) {
        return 1 if index($text, $needle) >= 0;
    }

    return 0;
}

sub collect_items {
    my ($spec, $where, $cache) = @_;

    my $request = $spec->{request};
    my $filter  = $spec->{filter};
    my $target  = $request->{pageSize};

    # 有 filter 时放大单次抓取量，筛选后再截断到 pageSize 条
    my $fetch_size = @$filter ? $DEFAULT_MAX_PAGESIZE : $target;
    my $page_request = { %$request, pageSize => $fetch_size };

    my $key = JSON::PP->new->utf8->canonical->encode($page_request);
    $cache->{$key} = fetch_items($page_request, $where)
        unless exists $cache->{$key};

    my @kept;
    for my $text (@{ $cache->{$key} }) {
        next unless keep_item($text, $filter);
        push @kept, $text;
        last if @kept >= $target;
    }

    return \@kept;
}

# ---------------------------------------------------------------- 下载与处理

sub fetch_items {
    my ($request, $where) = @_;

    my $body = JSON::PP->new->utf8->canonical->encode($request);

    my ($raw, $err);
    for my $attempt (1 .. $retry + 1) {
        my ($ok, $response, $why) = curl_post($body);
        if ($ok) {
            $raw = $response;
            $err = undef;
            last;
        }

        $err = $why;
        if ($attempt <= $retry) {
            warn "$where：请求失败（$err），1 秒后重试（$attempt/$retry）\n";
            sleep 1;
        }
    }
    fail("$where：请求 $api 失败（$err）\n") unless defined $raw;

    my $data = eval {
        JSON::PP->new->utf8->decode($raw);
    };
    if ($@) {
        my $e = $@;
        $e =~ s/\s+$//;
        fail("$where：响应不是合法 JSON（$e）\n");
    }

    fail("$where：响应不是 JSON 对象\n")
        unless ref($data) eq 'HASH';

    my $list = ref($data->{data}) eq 'HASH' ? $data->{data}{list} : undef;
    if (ref($list) ne 'ARRAY') {
        my $code = defined $data->{code} ? $data->{code} : '?';
        my $msg  = defined $data->{msg}  ? $data->{msg}  : '';
        fail("$where：响应缺少 data.list（code=$code, msg=$msg）\n");
    }

    my @items;
    for my $item (@$list) {
        my $text =
            ref($item) eq 'HASH' && defined $item->{barrage}
            ? $item->{barrage}
            : '';
        $text = '' if ref($text);

        $text =~ s/\s*\n\s*/ /g;
        $text =~ s/^\s+|\s+$//g;

        push @items, $text if length $text;
    }

    return \@items;
}

sub curl_post {
    my ($body) = @_;

    my @cmd = (
        'curl', '-fsS',
        '--max-time', $timeout,
        '-H', 'Content-Type: application/json',
        '-X', 'POST',
        '-d', $body,
        $api,
    );

    my $fh;
    unless (open($fh, '-|', @cmd)) {
        return (0, undef, "无法执行 curl：$!");
    }

    binmode($fh);
    my $raw;
    { local $/; $raw = <$fh>; }
    close($fh);

    my $status = $?;
    if ($status != 0) {
        my $code = $status >> 8;
        my $sig  = $status & 127;
        my $why  = $sig ? "curl 被信号 $sig 终止" : "curl 退出码 $code";
        return (0, undef, $why);
    }

    return (1, defined $raw ? $raw : '', undef);
}

# ---------------------------------------------------------------- 帮助

sub fail {
    my $message = join '', @_;
    print STDERR $message;
    exit 1;
}

sub usage {
    my ($code) = @_;

    my $fh = $code ? \*STDERR : \*STDOUT;
    print {$fh} <<"EOF";
expand_md.pl —— 把 Markdown 中的 <<<JSON>>> 标记替换为接口返回内容

用法:
  expand_md.pl [选项] <文件.md>

标记内的 JSON 字段:
  barrage   搜索关键词（必填）
  pageNum   页码，默认 1
  pageSize  最终保留的条目数，默认 10
  sort      排序，默认 0
  filter    可选字符串数组，仅保留包含任一项的条目
            （字面匹配、区分大小写；省略或 [] 表示不过滤）

处理规则:
  只请求一页，取 data.list 中每条的 barrage 字段；
  先折叠换行、去首尾空白并丢弃空条目，再按 filter 筛选；
  filter 非空时按 $DEFAULT_MAX_PAGESIZE 条/页抓取，最后仍只保留 pageSize 条；
  然后把保留条目中的 ~ 转义为 \\~，条目之间空一行。

选项:
  --api URL      接口地址（默认 $DEFAULT_API）
  --timeout SEC  curl 超时秒数，默认 $DEFAULT_TIMEOUT
  --retry N      失败重试次数，默认 $DEFAULT_RETRY
  --stdout       结果写到标准输出，不修改文件
  -h, --help     显示本帮助

示例:
  perl expand_md.pl README.md
  perl expand_md.pl --stdout README_Template.md > README.md
EOF

    exit $code;
}
