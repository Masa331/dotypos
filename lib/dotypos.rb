# frozen_string_literal: true

class Dotypos
  class AccessTokenExpired < StandardError; end
  class RefreshTokenExpired < StandardError; end
  class UnknownError < StandardError; end

  class ApiEnumerator < SimpleDelegator
    def initialize(base_url, data_key, params, api)
      @base_url = base_url
      @params = params
      @data_key = data_key
      @api = api

      @enum = Enumerator.new do |y|
        first_page.dig(@data_key).each { y.yield(_1) }

        if total_pages > 1
          (2..(total_pages - 1)).each do |page|
            @api.get(base_url, params.merge(page: page))
              .dig(@data_key)
              .each { y.yield(_1) }
          end

          last_page.dig(@data_key).each { y.yield(_1) }
        end
      end

      super(@enum)
    end

    def first_page
      @first_page ||= @api.get(@base_url, @params)
    end

    def last_page
      return first_page if total_pages < 2

      @last_page ||= @api.get(@base_url, @params.merge(page: total_pages))
    end

    def total_pages
      first_page.dig('lastPage').to_i || 0
    end

    def size
      first_page.dig('totalItemsCount').to_i
    end
  end

  def initialize(cloud_id, refresh_token, access_token, on_token_error)
    @cloud_id = cloud_id
    @refresh_token = refresh_token
    @access_token = access_token
    @on_token_error = on_token_error
  end

  attr_accessor :access_token

  def valid_credentials?
    get('branches')['code'] == '200'
  end

  def products(params = {})
    enumerize('products', 'data', params)
  end

  def categories(params = {})
    enumerize('categories', 'data', params)
  end

  def enumerize(base_url, data_key, params = {})
    ApiEnumerator.new(base_url, data_key, params, self)
  end

  def get(path, params = {}, retry_on_token_error = true)
    parsed = URI("https://api.dotykacka.cz/v2/clouds/#{@cloud_id}/" + path)
    parsed.query = URI.encode_www_form(params) if params.any?

    http = Net::HTTP.new(parsed.host, parsed.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(parsed)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request['Authorization'] = "Bearer #{@access_token}"

    response = http.request(request)

    if response.code == '403'
      raise Dotypos::AccessTokenExpired
    elsif response.code == '404' # Toto Dotypos API vraci pokud pro filtrovany dotaz je nula vysledku
      { 'code' => '404',
        'data' => [],
        'totalItemsCount' => 0,
        'lastPage' => 1
      }
    else
      parsed = JSON.parse(response.body)
      parsed.merge('code' => response.code)
    end
  rescue Dotypos::AccessTokenExpired
    if retry_on_token_error
      @on_token_error.call(self)
      get(path, params, false)
    end
  end

  def new_access_token
    uri = URI("https://api.dotykacka.cz/v2/signin/token")
    headers = {
      'Content-Type' => 'application/json',
      'Authorization' => "User #{@refresh_token}"
    }
    body = JSON.generate({ '_cloudId' => @cloud_id })

    req = Net::HTTP::Post.new(uri)
    headers.each do |key, value|
      req[key] = value
    end
    req.body = body

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(req)
    end

    if response.code == '200' || response.code == '201'
      JSON.parse(response.body)['accessToken']
    elsif response.code == '401'
      raise Dotypos::RefreshTokenExpired
    else
      raise Dotypos::UnknownError.new("#{response.code}: #{response.body}")
    end
  end
end
