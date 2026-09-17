require "rack/utm_cookies/version"

module Rack
  class UtmCookies
    def initialize(app, options = {})
      @app = app
      @domain = options[:domain] || nil
      @ttl = options[:ttl] || 60*60*24*30  # 30 days
    end

    def call(env)
      req = Rack::Request.new(env)

      # tack them on so they're available down
      # the middleware stack for this current request
      env['HTTP_COOKIE'] = '' unless env['HTTP_COOKIE']
      utm_cookies_to_set(req).each do |name, value|
        # HTTP_COOKIE arrives from the server as ASCII-8BIT; a value parsed
        # out of the query string is UTF-8. Appending one to the other raised
        # Encoding::CompatibilityError once both held non-ASCII bytes -- an ad
        # click carrying utm_term "séjour au pair" to a browser that already
        # held a raw utm_term cookie. Escaping makes the appended chunk
        # ASCII-only. It also stops a value containing ";" from splicing an
        # extra cookie into the header, and a value containing "+" from being
        # read back as a space. set_cookie_header! below already escapes, so
        # both sides of the round trip now unescape to the same value.
        env['HTTP_COOKIE'] += "; #{name}=#{Rack::Utils.escape(value)}"
      end

      # pass the call down the middleware stack
      status, headers, body = @app.call(env)

      # make sure the proper set-cookie response headers
      # are set so we have the cookies for future requests.
      utm_cookies_to_set(req).each do |name, value|
        cookie_hash = {
          :value => value,
          :expires => Time.now + @ttl,
          :path => '/',
        }
        cookie_hash[:domain] = @domain if @domain
        Rack::Utils.set_cookie_header!(headers, name, cookie_hash)
      end

      [status, headers, body]
    end

    private

    def utm_cookies_to_set(req)
      utm_cookies = {}
      # these are minimum required utm params
      if !(req.params["utm_source"] && req.params["utm_medium"] && req.params["utm_campaign"])
        return utm_cookies
      end

      utm_cookies = req.params.keep_if { |key|
        %{utm_source utm_medium utm_campaign utm_content utm_term}.include? key
      }

      return utm_cookies
    end

  end
end
