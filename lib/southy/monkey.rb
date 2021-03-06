require 'json'
require 'net/https'
require 'fileutils'
require 'pp'

class Southy::Monkey

  DEBUG = false

  def initialize(config = nil)
    @config = config
    @cookies = []

    @hostname = 'mobile.southwest.com'
    @api_key = 'l7xx12ebcbc825eb480faa276e7f192d98d1'

    @https = Net::HTTP.new @hostname, 443
    @https.use_ssl = true
    @https.verify_mode = OpenSSL::SSL::VERIFY_PEER
    @https.verify_depth = 5
    @https.ca_path = '/etc/ssl/certs' if File.exists? '/etc/ssl/certs'  # Ubuntu
  end

  def core_form_data
    { :appID => 'swa', :appver => '2.17.0', :channel => 'wap', :platform => 'thinclient', :cacheid => '', :rcid => 'spaiphone' }
  end

  def parse_json(response)
    if response.body == nil || response.body == ''
      @config.log "Empty response body returned"
      return { 'errmsg' => "empty response body - #{response.code} (#{response.msg})"}
    end
    JSON.parse response.body
  end

  def validate_airport_code(code)
    if Southy::Airport.lookup code
      true
    else
      @config.log "Unknown airport code: #{code}"
      false
    end
  end

  def extract_flights(record_locator, passengers, segment)
    depart_code = segment['originationAirportCode']
    arrive_code = segment['destinationAirportCode']
    return nil unless validate_airport_code(depart_code) && validate_airport_code(arrive_code)

    passengers.map do |passenger|
      flight = Southy::Flight.new
      flight.first_name = passenger['secureFlightName']['firstName'].capitalize
      flight.last_name = passenger['secureFlightName']['lastName'].capitalize
      flight.confirmation_number = record_locator
      flight.number = segment['operatingCarrierInfo']['flightNumber']
      flight.depart_code = depart_code
      flight.depart_airport = Southy::Airport.lookup(depart_code).name
      flight.depart_date = DateTime.parse(segment['departureDateTime'])
      flight.arrive_code = arrive_code
      flight.arrive_airport = Southy::Airport.lookup(arrive_code).name
      flight
    end
  end

  def alternate_names(first, last)
    f, l = first.split(' '), last.split(' ')
    if f.length == 1 && l.length == 2
      return [ "#{f[0]} #{l[0]}", l[1] ]
    elsif f.length == 2 && l.length == 1
      return [ f[0], "#{f[1]} #{l[0]}" ]
    end
    [ first, last ]
  end

  def fetch_trip_info(conf, first_name, last_name)
    uri = URI("https://#{@hostname}/api/extensions/v1/mobile/reservations/record-locator/#{conf}")
    uri.query = URI.encode_www_form(
      'first-name' => first_name,
      'last-name'  => last_name,
      'action'     => 'VIEW'
    )
    request = Net::HTTP::Get.new uri
    json = fetch_json request
    @config.save_file conf, 'record-locator.json', json
    json
  end

  def lookup(conf, first_name, last_name)
    json = fetch_trip_info conf, first_name, last_name
    errmsg = json['errmsg']

    if errmsg && errmsg != ''
      alternate_names(first_name, last_name).tap do |alt_first, alt_last|
        if alt_first != first_name || alt_last != last_name
          json = fetch_trip_info conf, alt_first, alt_last
          errmsg = json['errmsg']
        end
      end
    end

    if errmsg && errmsg != ''
      ident = "#{conf} #{first_name} #{last_name}"
      return { error: 'cancelled', flights: [] } if errmsg =~ /SW107028/
      return { error: 'invalid', flights: [] } if errmsg =~ /SW107023/

      if json['opstatus'] != 0
        @config.log "Technical error looking up flights for #{ident} - #{errmsg}"
        return { error: 'unknown', reason: errmsg, flights: [] }
      end

      @config.log "Unknown error looking up flights for #{ident} - #{errmsg}"
      return { error: 'unknown', reason: errmsg, flights: [] }
    end

    itinerary = json['itinerary']
    return { error: 'failure', reason: 'no itinerary', flights: [] } unless itinerary

    originations = itinerary['originationDestinations']
    return { error: 'failure', reason: 'no origination destinations', flights: [] } unless originations

    record_locator = json['recordLocator']
    passengers = json['passengers']
    response = { error: nil, flights: {} }
    originations.each do |origination|
      segments = origination['segments']
      return { error: 'failure', reason: 'no segments', flights: [] } unless segments

      segments.each do |segment|
        segment_conf = record_locator
        flights = extract_flights record_locator, passengers, segment
        response[:flights][segment_conf] ||= []
        response[:flights][segment_conf] += flights
      end
    end

    response
  end

  def fetch_checkin_info(conf, first_name, last_name)
    uri = URI("https://#{@hostname}/api/extensions/v1/mobile/reservations/record-locator/#{conf}/boarding-passes")
    request = Net::HTTP::Post.new uri
    request.body = {
      :names => [ {
        :firstName => first_name.upcase,
        :lastName =>  last_name.upcase
      } ]
    }.to_json
    json = fetch_json request
    @config.save_file conf, "boarding-passes-#{first_name.downcase}-#{last_name.downcase}.json", json
    json
  end

  def checkin(flights)
    @cookies = []
    checked_in_flights = []
    flights.each do |flight|
      json = fetch_checkin_info flight.confirmation_number, flight.first_name, flight.last_name

      passengerCheckins = json['passengerCheckInDocuments'] || []
      if passengerCheckins.length == 0
        alternate_names(flight.first_name, flight.last_name).tap do |alt_first, alt_last|
          if alt_first != flight.first_name || alt_last != flight.last_name
            json = fetch_checkin_info flight.confirmation_number, alt_first, alt_last
            passengerCheckins = json['passengerCheckInDocuments'] || []
          end
        end
      end

      if passengerCheckins.length == 0 && json['code']
        @config.log " --> #{flight.conf} (#{flight.full_name}) - #{json['code']} #{json['httpStatusCode']} - #{json['message']}"
      end

      passengerCheckins.each do |pc|
        passenger = pc['passenger']
        fname = passenger['secureFlightFirstName'].downcase
        lname = passenger['secureFlightLastName'].downcase

        pc['checkinDocuments'].each do |cd|
          num = cd['flightNumber']
          flight = flights.find do |f|
            f.number == num && f.first_name.downcase == fname && f.last_name.downcase == lname
          end
          if flight
            flight.group = cd['boardingGroup']
            flight.position = cd['boardingGroupNumber']
            checked_in_flights << flight
          end
        end
      end
    end

    @cookies = []
    { :flights => checked_in_flights.compact }
  end

  private

  def fetch_json(request, n = 0)
    puts "Fetch #{request.path}" if DEBUG
    request['User-Agent'] = 'Mozilla/5.0 (iPhone; CPU iPhone OS 8_0 like Mac OS X) AppleWebKit/600.1.3 (KHTML, like Gecko) Version/8.0 Mobile/12A4345d Safari/600.1.4'
    request['Content-Type'] = 'application/vnd.swacorp.com.mobile.boarding-passes-v1.0+json'
    request['X-API-Key'] = @api_key

    restore_cookies request
    response = @https.request(request)

    json = parse_json response

    if json['errmsg'] && json['opstatus'] != 0 && n <= 10  # technical error, try again (for a while)
      fetch_json request, n + 1
    else
      save_cookies response
      json
    end
  end

  def restore_cookies(request)
    request['Cookie'] = @cookies.join('; ') if @cookies.length
  end

  def save_cookies(response)
    cookie_headers = response.get_fields('Set-Cookie') || []
    cookie_headers.each do |c|
      @cookies << c.split(';')[0]
    end
  end
end

class Southy::TestMonkey < Southy::Monkey
  def get_json(conf, name)
    base = File.dirname(__FILE__) + "/../../test/fixtures/#{conf}/#{name}"
    last = "#{base}.json"
    n = 1
    while File.exist? "#{base}_#{n}.json"
      last = "#{base}_#{n}.json"
      n += 1
    end
    JSON.parse IO.read(last).strip
  end

  def fetch_trip_info(conf, first_name, last_name)
    get_json conf, "record-locator"
  end
end
