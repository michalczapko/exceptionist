require 'digest'
require 'nokogiri'

class Occurrence < Exceptionist::Model
  attr_accessor :url, :controller_name, :action_name,
                :exception_class, :exception_message, :exception_backtrace,
                :parameters, :session, :cgi_data, :environment,
                :project_name, :occurred_at, :id, :uber_key

  def title
    "#{exception_class} in #{controller_name}##{action_name}"
  end

  def http_method
    cgi_data ? cgi_data['REQUEST_METHOD'] : nil
  end

  def referer
    cgi_data ? cgi_data['HTTP_REFERER'] : nil
  end

  def user_agent
    cgi_data ? cgi_data['HTTP_USER_AGENT'] : nil
  end

  def occurred_at
    @occurred_at.is_a?(String) ? DateTime.parse(@occurred_at) : @occurred_at
  end

  def close!
    # do this here, because the UberException does not know which project it's in
    redis.set_delete("Exceptionist::UberExceptions:#{project_name}", uber_key)
  end

  def project
    Project.new(project_name)
  end

  def to_hash
    { :exception_message   => exception_message,
      :session             => session,
      :action_name         => action_name,
      :parameters          => parameters,
      :cgi_data            => cgi_data,
      :url                 => url,
      :occurred_at         => occurred_at,
      :exception_backtrace => exception_backtrace,
      :controller_name     => controller_name,
      :environment         => environment,
      :exception_class     => exception_class,
      :project_name        => project_name,
      :id                  => id,
      :uber_key            => uber_key }
  end

  def self.from_xml(xml_text)
    hash = parse_xml(xml_text)
    key = Digest::SHA1.hexdigest([:controller_name, :action_name, :exception_class].map { |k| hash[k] }.join(':'))
    new(hash.merge(:occurred_at => Time.now, :uber_key => key))
  end

  def self.parse_xml(xml_text)
    doc = Nokogiri::XML(xml_text) { |config| config.noblanks }

    hash = {}
    hash[:project_name] = doc.xpath('/notice/api-key').first.content
    hash[:environment]  = doc.xpath('/notice/server-environment/environment-name').first.content

    hash[:exception_class]     = doc.xpath('/notice/error/class').first.content
    hash[:exception_message]   = parse_optional_element(doc, '/notice/error/message')
    hash[:exception_backtrace] = doc.xpath('/notice/error/backtrace').children.map do |child|
      "#{child['file']}:#{child['number']}:in `#{child['method']}'"
    end

    if request = doc.xpath('/notice/request').first
      hash[:url]             = request.xpath('url').first.content
      hash[:controller_name] = request.xpath('component').first.content
      hash[:action_name]     = parse_optional_element(request, 'action')

      hash[:parameters]  = parse_vars(doc.xpath('/notice/request/params'))
      hash[:session]     = parse_vars(doc.xpath('/notice/request/session'))
      hash[:cgi_data] = parse_vars(doc.xpath('/notice/request/cgi-data'), :skip_rack => true)
    end

    hash
  end

  def self.parse_vars(node, options = {})
    node.children.inject({}) do |hash, child|
      key = child['key']
      hash[key] = child.content unless (options[:skip_rack] && key.include?('.'))
      hash
    end
  end

  def self.parse_optional_element(doc, xpath)
    element = doc.xpath(xpath).first
    element ? element.content : nil
  end
end
