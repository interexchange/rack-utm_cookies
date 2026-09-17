require 'spec_helper'
require 'rack/test'
# require 'rack/mock'
require 'byebug'
require 'awesome_print'

# idea from http://stackoverflow.com/questions/17506567/testing-middleware-with-rspec
class MockRackApp
  attr_reader :env

  def call(env)
    @env = env
    [200, {'Content-Type' => 'text/plain'}, ['OK']]
  end
end

module Rack
  module Test
    # otherwise it's example.org - and we want to be a bit more explicit
    # when testing cookies set for root vs sub domains
    DEFAULT_HOST = "www.example.com"
  end
end

describe Rack::UtmCookies do
  include Rack::Test::Methods

  let(:nested_rack_app) { MockRackApp.new }
  let(:app) { Rack::UtmCookies.new(nested_rack_app) }
  let(:request) { Rack::MockRequest.new(app) }
  let(:endpoint) { '/?utm_source=the_source&utm_medium=the_medium&utm_campaign=the_campaign&utm_content=the_content&utm_term=the_term' }

  def cookies
    rack_mock_session.cookie_jar.instance_variable_get(:@cookies)
  end

  it 'has a version number' do
    expect(Rack::UtmCookies::VERSION).not_to be nil
  end

  it 'tacks on UTM cookies before passing response down the middleware stack' do
    get(endpoint)
    # we DON'T want to just check cookies from the response like other methods - we
    # explicitly want the cookies in the request that gets passed on to our NESTED
    # rack app
    req = Rack::Request.new(nested_rack_app.env)
    expect(req.cookies['utm_source']).to eq('the_source')
    expect(req.cookies['utm_medium']).to eq('the_medium')
    expect(req.cookies['utm_campaign']).to eq('the_campaign')
    expect(req.cookies['utm_content']).to eq('the_content')
    expect(req.cookies['utm_term']).to eq('the_term')
  end

  it "does nothing if the minimum required params of utm_source, utm_medium and utm_campaign aren't present" do
    get('/?utm_source=the_source&utm_campaign=the_campaign')
    expect(cookies.count).to eq(0)
  end

  it 'sets cookies for the current subdomain in the response' do
    get(endpoint)
    expect(rack_mock_session.cookie_jar["utm_source"]).to eq('the_source')
    expect(rack_mock_session.cookie_jar["utm_medium"]).to eq('the_medium')
    expect(rack_mock_session.cookie_jar["utm_campaign"]).to eq('the_campaign')
    expect(rack_mock_session.cookie_jar["utm_content"]).to eq('the_content')
    expect(rack_mock_session.cookie_jar["utm_term"]).to eq('the_term')

    cookies.each do |c|
      expect(c.domain).to eq('www.example.com')
    end
  end

  context 'with domain option' do
    let(:app) { Rack::UtmCookies.new(nested_rack_app, {
        domain: '.example.com'
      }) }

    it 'sets cookies to the domain passed in' do
      get(endpoint)
      expect(cookies.count).to eq(5)
      cookies.each do |c|
        # RFC 6265 drops the leading dot, and rack-test normalises to match, so
        # a cookie sent as domain=".example.com" reads back as "example.com".
        expect(c.domain).to eq('example.com')
      end
    end
  end

  context 'with a non-ASCII utm value' do
    let(:term) { 'séjour au pair' }
    let(:endpoint) do
      '/?utm_source=adwords&utm_medium=ppc&utm_campaign=fr&utm_term=' +
        Rack::Utils.escape(term)
    end

    # The browser holds a utm_term cookie written raw by JavaScript, so the
    # Cookie header the server hands Rack is ASCII-8BIT *and* carries non-ASCII
    # bytes. That is the combination that used to raise; a header of pure ASCII
    # concatenates with a UTF-8 value without complaint.
    let(:returning_visitor) do
      { 'HTTP_COOKIE' => "hubspotutk=abc; utm_term=#{ term }".dup.force_encoding(Encoding::ASCII_8BIT) }
    end

    it 'does not raise when the incoming cookie header is binary' do
      expect { get(endpoint, {}, returning_visitor) }.not_to raise_error
    end

    it 'passes the value down the stack so it parses back unchanged' do
      get(endpoint, {}, returning_visitor)
      expect(Rack::Request.new(nested_rack_app.env).cookies['utm_term']).to eq(term)
    end

    it 'sets the response cookie to the value that was sent' do
      get(endpoint, {}, returning_visitor)
      expect(rack_mock_session.cookie_jar['utm_term']).to eq(term)
    end
  end

  it 'keeps a "+" in a value from being read back as a space' do
    get('/?utm_source=the_source&utm_medium=the_medium&utm_campaign=the_campaign&utm_term=' +
      Rack::Utils.escape('a+b'))
    expect(Rack::Request.new(nested_rack_app.env).cookies['utm_term']).to eq('a+b')
  end

  it 'does not let a ";" in a value splice an extra cookie into the header' do
    # A crafted link is the whole input here: the value below arrived as a
    # query parameter, and unescaped it ends the utm_campaign cookie and starts
    # one the visitor never had.
    get('/?utm_source=the_source&utm_medium=the_medium&utm_campaign=' +
      Rack::Utils.escape('the_campaign; evil=pwned'))
    downstream = Rack::Request.new(nested_rack_app.env).cookies
    expect(downstream['utm_campaign']).to eq('the_campaign; evil=pwned')
    expect(downstream).not_to have_key('evil')
  end
end
