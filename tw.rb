%w<base64 eventmachine paint readline yajl simple_oauth http/parser>.each do |dep|
  require dep
end

class C < EM::Connection
  attr_accessor :each, :error, :auth

  def initialize(uri, method, params={})
    @method = method
    @uri = uri
    @params = params
  end

  def post_init
    @http = Http::Parser.new
    @http.on_headers_complete = method(:headers_complete)
    @http.on_body = method(:body)
    @json = Yajl::Parser.new(symbolize_keys: true)
    @json.on_parse_complete = method(:dispatch)
  end

  def connection_completed
    header = { Host: @uri.host, Accept: "*/*", Authorization: @auth[@method, @uri.to_s, @params] }
    params = @params.map{|k,v| "#{URI.escape(k.to_s)}=#{URI.escape(v.to_s)}" }.sort.join("&")
    path = @uri.path
    path << "?#{params}" if @method == "GET" and not params.empty?
    body = params if @method == "POST" and not params.empty?
    request = [] << "#{@method} #{path} HTTP/1.1"
    header.each{|k,v| request << "#{k}: #{v}" }
    request << "Content-Type: application/x-www-form-urlencoded" if @method == "POST"
    request << "Content-Length: #{body.length}" if @method == "POST"
    request << "\r\n"
    request = request.join("\r\n") << (body||"")
    send_data request
  end

  def headers_complete(data)
    @code = @http.status_code.to_i
  end

  def receive_data(data)
    @http << data
  end

  def body(data)
    if @code == 200
      @json << data
    else
      @error[@code] if @error
      EM.stop
    end
  end

  def dispatch(data)
    @each[data] if @each
  end

  def unbind
    @error["disconnected"]
  end

  def self.connect(uri, method, params={})
    port = uri.scheme=="https" ? 443 : 80
    conn = EM.connect(uri.host, port, self, uri, method, params)
    conn.start_tls if port==443
    conn
  end
end

class T
  def self.run(&block)
    EM.run do
      self.new.instance_eval(&block)
    end
  end

  def auth(&block)
    @auth = block
  end

  def error(&block)
    @error = block
  end

  def each(&block)
    @each = block
  end

  def defer(&block)
    EM.defer &block
  end

  def basic(login)
    "Basic #{Base64.encode64("#{login}")}".chop
  end

  def track(keywords)
    connect(URI("https://stream.twitter.com/1/statuses/filter.json"), "POST", { track: keywords.join(",") })
  end

  def user
    connect(URI("https://userstream.twitter.com/2/user.json"), "GET")
  end

  def connect(uri, method, params={})
    @conn.close_connection if @conn
    reconnect = lambda do
      return EM.add_timer(1, reconnect) if EM.connection_count > 0
      @conn = C.connect(uri, method, params)
      Readline.refresh_line
      @conn.each,@conn.error,@conn.auth = @each,@error,@auth
    end
    EM.next_tick(reconnect)
  end

  def stop
    EM.stop
  end
end

def putr(message="", *attrs)
  io = StringIO.new
  io.puts(Paint[message, *attrs])
  print("\e[0G\e[K" << io.string)
end

T.run do
  queue = Queue.new

  config = Yajl::Parser.parse(File.open("tw.config"), symbolize_keys: true)

  auth do |method, uri, params|
    SimpleOAuth::Header.new(method, uri, params, config)
  end

  defer do
    while input = Readline.readline(Paint[">> ", :green, :bold])
      next if input.empty?
      Readline::HISTORY.push(input) unless input == Readline::HISTORY.to_a[-1]
      input = input.split(" ")
      case input[0]
      when "user"
        user
        queue.clear
      when "track"
        track(input[1..-1])
        queue.clear
      when "exit"
        stop
      end
    end
  end

  defer do
    loop do
      if Readline.line_buffer.empty?
        queue.pop.tap do |q|
          putr q
          Readline.refresh_line
        end
      else
        sleep(0.5)
      end
    end
  end

  each do |item|
    if item.key?(:text)
      user = Paint[item[:user][:screen_name], :yellow, :bold]
      retweet = item[:retweeted_status]
      user << '>' << Paint[retweet[:user][:screen_name], :magenta, :bold] if retweet
      item = retweet if retweet
      item[:text].gsub!(%r<(@[^\s]+)>,          Paint['\\1', :cyan, :bold])
      item[:text].gsub!(%r<(https?://[^\s]+)>i, Paint['\\1', :red, :bold])
      item[:text].gsub!(%r<(#[^\s]+)>,          Paint['\\1', :green, :bold])
      queue.push "#{user}: " << CGI.unescapeHTML(item[:text]).strip.chomp.gsub(/\s+/, ' ')
    end
  end

  error do |message|
    putr message, :red, :bold
  end

  user
end
