require 'socket'
require 'openssl'
require 'json'

module APNS

  class Error < Exception; end
  class ConfigurationError < Error; end

  @host = 'gateway.sandbox.push.apple.com'
  @port = 2195
  # openssl pkcs12 -in mycert.p12 -out client-cert.pem -nodes -clcerts
  @pem = nil # this should be the path of the pem file not the contentes
  @pass = nil
  @pem_data = nil
  
  @persistent = false
  @mutex = Mutex.new
  @retries = 3 # TODO: check if we really need this
  
  @sock = nil
  @ssl = nil
  
  class << self
    attr_accessor :host, :pem, :port, :pass, :pem_data
  end
  
  def self.start_persistence
    @persistent = true
  end
  
  def self.stop_persistence
    @persistent = false
    
    @ssl.close
    @sock.close
  end
  
  def self.send_notification(device_token, message)
    n = APNS::Notification.new(device_token, message)
    self.send_notifications([n])
  end
  
  def self.send_notifications(notifications)
    @mutex.synchronize do
      self.with_connection do
        notifications.each do |n|
          @ssl.write(n.packaged_notification)
        end
      end
    end
  end
  
  def self.feedback
    sock, ssl = self.feedback_connection

    apns_feedback = []

    while line = ssl.read(38)   # Read lines from the socket
      line.strip!
      f = line.unpack('N1n1H140')
      apns_feedback << { :timestamp => Time.at(f[0]), :token => f[2] }
    end

    ssl.close
    sock.close

    return apns_feedback
  end
  
protected
  
  def self.with_connection
    attempts = 1
  
    begin      
      # If no @ssl is created or if @ssl is closed we need to start it
      if @ssl.nil? || @sock.nil? || @ssl.closed? || @sock.closed?
        @sock, @ssl = self.open_connection
      end
    
      yield
    
    rescue StandardError, Errno::EPIPE
      raise unless attempts < @retries
    
      @ssl.close unless @ssl.nil?
      @sock.close unless @sock.nil?
    
      attempts += 1
      retry
    end
  
    # Only force close if not persistent
    unless @persistent
      @ssl.close
      @ssl = nil
      @sock.close
      @sock = nil
    end
  end
  
  def self.open_connection
    sock         = TCPSocket.new(self.host, self.port)
    ssl          = OpenSSL::SSL::SSLSocket.new(sock, context)
    ssl.connect

    return sock, ssl
  end
  
  def self.feedback_connection
    fhost = self.host.gsub('gateway','feedback')
    
    sock         = TCPSocket.new(fhost, 2196)
    ssl          = OpenSSL::SSL::SSLSocket.new(sock, context)
    ssl.connect

    return sock, ssl
  end

  def self.context
    context      = OpenSSL::SSL::SSLContext.new
    context.cert = OpenSSL::X509::Certificate.new(pem_data)
    context.key  = OpenSSL::PKey::RSA.new(pem_data, pass)
    context
  end

  def self.pem_data
    return @pem_data if @pem_data

    if pem
      raise ConfigurationError.new("The path to your pem file does not exist!") unless File.exist?(pem)
      @pem_data = File.read(pem)
    else
      message =<<-EOT
Supply the path to your pem file, or the binary pem data:
E.g.:
  APNS.pem = /path/to/cert.pem
or
  APNS.pem_data = binary_pem_data
      EOT
      raise ConfigurationError.new(message)
    end
  end
  
end
