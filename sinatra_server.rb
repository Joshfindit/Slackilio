require "rubygems"
require "sinatra"
require "rest-client"
require 'open-uri'
require 'addressable/uri'
require 'twilio-ruby'

configure do
  set :thisHostNameorIP, '' # The server talks to itself on this host. Did not do localhost so that the server can be split later if desired.
  set :slackToken, '' # Your Slack token
  set :slackBotUsername, 'Twilio' # In the code below, this server will set the slackbot username to `Twilio-#{The number the caller called}`. This slackbot username is used when there is no number for it to use.
  set :slackPostMessageEndpoint, 'https://slack.com/api/chat.postMessage'
  set :slackCreateChannelEndpoint, 'https://slack.com/api/channels.create'
  set :slackSetChannelPurposeEndpoint, 'https://slack.com/api/channels.setPurpose'
  set :slackSlashCommandTokenSMS, '' # The Slack token for the `/sms` command
  set :slackSlashCommandTokenTXT, '' # Interesting tidbit: Slack does not properly work with `/txt`
  set :slackSlashCommandTokenS, '' # The Slack token for the `/S` command
  set :slackSlashCommandTokenCall, '' # The Slack token for the `/call` command
  set :slackSlashCommandTokenCallFrom, '' # The Slack token for the `/callfrom` command
  set :twilioAccountSID, '' # Your Twilio Account SID
  set :twilioAuthToken, '' # Your Twilio Auth Token
  set :twilioOutsideNumber, '18445551212' # Your public-facing Twilio number. This is what people call, and what you want your callerID to show up as.
  set :twilioSecondOutsideNumber, '18445551414' # Having a second outside number allows you to do conference calls without tying up the line.
  set :twilioConferenceCreateEndpoint, ''
  set :myMobileNumber, '18005551212' # This is the number that will ring when someone calls your Twilio number
  set :myMobileNumber2, '18885551212' # This is the number that will also ring when someone calls your Twilio number
end

# Could expand this to the other Twilio-specific URLs as well
use Rack::TwilioWebhookAuthentication, settings.twilioAuthToken, '/slackilio/incomingsms' #verifies that only Twilio can post to the 'incomingsms' url. As per http://thinkvoice.net/twilio-sms-forwarding/

set :port, 8080
set :environment, :production

error Sinatra::NotFound do
  content_type 'text/plain'
  [404, 'Not Found']
end

def sanitize_number (string)
   if sanitized = string.gsub(/[^\d]/, '') #watch out: if no gsub match, ruby freaks out
     return sanitized
   else
     return string
  end
end


def postMessage(channel, messageText)

  slackPostMessageEndpoint = "https://slack.com/api/chat.postMessage"
  uri = Addressable::URI.parse(settings.slackPostMessageEndpoint)
  if params[:Called]
    puts "Changing the Slackbot username to #{params[:Called]}"
    query = {token: settings.slackToken, channel: "##{channel}", text: messageText, username: "Twilio-#{params[:Called]}"}
  else
    query = {token: settings.slackToken, channel: "##{channel}", text: messageText, username: settings.slackBotUsername}
  end
  uri.query_values ||= {}
  uri.query_values = uri.query_values.merge(query)

  results = Net::HTTP.get(URI.parse(uri))
  puts "Message posted to Slack?: #{results['ok']}"
  return results['ok']
end


def createChannel(channel)
  uri = Addressable::URI.parse(settings.slackCreateChannelEndpoint)
  query = {token: settings.slackToken, name: "##{channel}"}
  uri.query_values ||= {}
  uri.query_values = uri.query_values.merge(query)
  if results = JSON.parse(Net::HTTP.get(URI.parse(uri)))
    puts "Channel ID: #{results['channel']['id']}. Setting purpose:"
    puts setChannelPurpose(results['channel']['id'], "SMS Conversation with: #{params[:From]} From: #{params[:FromCity].capitalize}, #{params[:FromState]}")
    #puts "From: #{params[:From]}")
    return results['ok']
  end
end


def setChannelPurpose(channelID, purpose)
  uri = Addressable::URI.parse(settings.slackSetChannelPurposeEndpoint)
  query = {token: settings.slackToken, channel: channelID, purpose: purpose}
  uri.query_values ||= {}
  uri.query_values = uri.query_values.merge(query)

  results = JSON.parse(Net::HTTP.get(URI.parse(uri)))
  return results['ok']
end


def startConference(to, from, myNumber) #"to" is the recipient. myNumber is the caller
  begin
    @client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
    @call = @client.account.calls.create(
      :from => "+#{from}",   # From your Twilio number
      #:to => '+#{myCurrentPhoneNumber}',     # To any number
      :to => "+#{myNumber}", #to me
      :timeout => 7, #Only try me for 7 seconds
      #:record => true, #creates a second recording? Yes.
      # Fetch instructions from this URL when the call connects
      :url => "http://#{settings.thisHostNameorIP}:#{settings.port}/slackilio/startconferenceroom?room=#{to}",
    )
    puts "Creating the conference by calling the first participant (#{myNumber}): #{@call.status}"
  rescue Twilio::REST::RequestError => e
    #If Twilio reports an error, rescue
    puts "Twilio reports call failed: #{e.message}"
    postMessage(params[:channel_name], "CALL command failed. Twilio reports:e #{e.message}")
  else
    #Send was successful (probably)
    #postMessage(params[:channel_name], "#{params[:user_name]} sent SMS: #{params[:text]}")
    puts "Called through Twilio successfully (to me)"
  end
end


def joinConference(to, from) #Note: the from number has to be different than the one used for the started conference
  begin
    @client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
    @call = @client.account.calls.create(
      :from => "+#{from}",   # From your Twilio number
      :to => "+#{to}", #the recipient
      :record => true, #creates a second recording?
      # Fetch instructions from this URL when the call connects
      :url => "http://#{settings.thisHostNameorIP}:#{settings.port}/slackilio/outgoingconferenceroom?room=#{to}",
      :status_callback => "http://#{settings.thisHostNameorIP}:#{settings.port}/slackilio/callstatus?number=#{to}",
      :status_callback_method => "POST",
      :status_callback_event => ["completed"]
    )
    puts "Joining #{to} to the conference: #{@call.status}"
  rescue Twilio::REST::RequestError => e
    #If Twilio reports an error, rescue
    puts "Twilio reports call failed: #{e.message}"
    postMessage(params[:channel_name], "CALL command failed. Twilio reports:e #{e.message}")
  else
    #Send was successful (probably)
    #postMessage(params[:channel_name], "#{params[:user_name]} sent SMS: #{params[:text]}")
    puts "Called through Twilio successfully (to #{to})"
  end
end


def conferenceInfo() #unfinished.
  #Finding information about conference rooms
  @client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
  @client.account.conferences.list({ :friendly_name => probablePhoneNumber}).each do |conference|
    puts "found conference before creation: #{conference.friendly_name}. #{conference.status}."
    #p conference
  end
end


post '/slackilio/forwardtomobile' do # Forwards the call to a mobile number
  puts "received to /slackilio/forwardtomobile"
  postMessage("twilio-status", "**incoming call to #{params[:Called]} from #{params[:From]} (#{params[:CallerName]}). [received to /slackilio/forwardtomobile]")
  p params
  
  #twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Dial record='record-from-ringing' timeout='14'>#{settings.myMobileNumber}</Dial></Response>"
  #Note: Dial 'action' in this case will continue to record the caller even after I hang up
  puts twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Dial action='http://#{settings.thisHostNameorIP}:#{settings.port}/slackilio/voicemail' record='record-from-ringing' timeout='14'><Number>#{settings.myMobileNumber}</Number><Number>#{settings.myMobileNumber2}</Number></Dial></Response>"

  content_type 'text/xml'
  twiml

end


post '/slackilio/forwardtomobilewithtones' do # This route plays three tones when you answer the call. Handy for knowing whether this is a Twilio call or a regular cell call.
  puts "received to /slackilio/forwardtomobilewithtones"
  postMessage("twilio-status", "**incoming call to #{params[:Called]} from #{params[:From]} (#{params[:CallerName]}). [received to /slackilio/forwardtomobilewithtones]")
  #puts twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Dial action='http://#{settings.thisHostNameorIP}:#{settings.port}/slackilio/voicemail' record='record-from-ringing' timeout='14'><Number sendDigits='333'>#{settings.myMobileNumber}</Number><Number sendDigits='333'>#{settings.myMobileNumber2}</Number></Dial></Response>"
  p params
  content_type 'text/xml'
  #twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Dial record='record-from-ringing' timeout='14'>#{settings.myMobileNumber}</Dial></Response>"
  #Note: Dial 'action' in this case will continue to record the caller even after I hang up

  puts twiml = "<?xml version='1.0' encoding='UTF-8'?><Response><Dial action='http://#{settings.thisHostNameorIP}:#{settings.port}/slackilio/voicemail' record='record-from-ringing' timeout='14'><Number sendDigits='333'>#{settings.myMobileNumber}</Number></Dial></Response>"

  twiml

end


post '/slackilio/incomingsms' do #Received an SMS from Twilio; post to Slack. Create the 'sms' channel if needed and set topic to the caller ID

  puts "POST request received to /slackilio/incomingsms - an SMS was sent to the external Twilio number"
  # p params

  postMessageBody = "From: #{params[:From]}: #{params[:Body]}"

  sanitizedNumber = sanitize_number(params[:From]).to_s
  prospectiveChannel = "sms#{sanitizedNumber}"

  #Get the list of channels, and search for an already existing one matching the prospectiveChannel
  uri = URI.parse("https://slack.com/api/channels.list?token=#{settings.slackToken}&pretty=1")
  res = Net::HTTP.get_response(uri)
  # puts res.code #200 on success
  channelsList = JSON.parse(res.body)
  #We now have the channel JSON, now hash it for easy lookups
  channelsListByName = Hash[channelsList['channels'].map { |h| h.values_at('name', 'id') }]

  if number = channelsListByName[prospectiveChannel]
    puts "Channel was found! Posting Message!"
    res = postMessage(prospectiveChannel, postMessageBody)
    puts "postMessage results: #{res}"
  else
    puts "Channel was not found :( Creating channel! :)"
    # if create channel returns 200
    if createChannel(prospectiveChannel)
      puts "Channel created! Posting Message!"
      res = postMessage(prospectiveChannel, postMessageBody)
    else
      # freak out because we couldn't create a channel
      postMessage("twilio-status", "Could not create #{prospectiveChannel}")
    end
  end
end


post '/slackilio/outgoingsms' do #Sending an SMS from Slack to Twilio
  #  p params

  puts "POST request recieved to /slackilio/outgoingsms. Send an SMS."
  if params[:token] == settings.slackSlashCommandTokenSMS || params[:token] == settings.slackSlashCommandTokenTXT || params[:token] == settings.slackSlashCommandTokenS
    puts "channel_id: #{params[:channel_name]}"
    puts "text: #{params[:text]}"
    puts "sanitize_number(params[:channel_name]): #{sanitize_number(params[:channel_name])}"

    # strip 'sms' from params[:channel_name]
    if potentialPhoneNumber = sanitize_number(params[:channel_name])
      # Check if it's an 11 digit number ("18005551221".length = 11)
      if potentialPhoneNumber.length == 11
        probablePhoneNumber = potentialPhoneNumber
      # Send to Twilio
        @client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
        #Send the SMS
        begin
          @client.account.messages.create({
            :from => "+#{settings.twilioOutsideNumber}",
            :to => "+#{probablePhoneNumber}",
            :body => params[:text],
          })
        rescue Twilio::REST::RequestError => e
          #If Twilio reports an error, rescue
          puts "Twilio reports sms failed: #{e.message}"
          postMessage(params[:channel_name], "SMS command failed. Twilio reports:e #{e.message}")
        else
          #Send was successful (probably)
          postMessage(params[:channel_name], "#{params[:user_name]} sent SMS: #{params[:text]}")
          puts "Sms sent through Twilio successfully"
        end
      else
        #Send a message to the channel stating that a phone number wasn't found
        postMessage(params[:channel_name], "SMS command failed - the channel name does not contain an 11 digit number. Wrong channel?")
        halt
      end
    end

    #return "Slack slash command received and processed."
  else
    puts "Token from Slack doesn't match. Aborting."
    halt
  end
end


# When slack sends the slash command to make a call, Twilio takes over and either tries to call myMobileNumber, or in the case of `/callfrom`, Twilio will call the number specified.
# When someone picks up at that number, it then dials out and conferences in the number called.

post '/slackilio/outgoingphonecall' do
  #  p params

  puts "POST request recieved to /slackilio/outgoingphonecall. Calling the forwarding number (settings.myMobileNumber)"
  if params[:token] == settings.slackSlashCommandTokenCall || params[:token] == settings.slackSlashCommandTokenCallFrom
    # Slack slash command received and processed.
    puts "channel_id: #{params[:channel_name]}"
    puts "manualNumber: #{params[:text]}"
    #    puts sanitize_number(params[:channel_name])

    #Create a recorded conference room
    # strip sms from params[:channel_name]
    if potentialPhoneNumber = sanitize_number(params[:channel_name]) #Get the outgoing number
      # Check if it's an 11 digit number
      #      puts "potentialPhoneNumber: #{potentialPhoneNumber}"
      #      puts "potentialPhoneNumber.length: #{potentialPhoneNumber.length}"
      if potentialPhoneNumber.length == 11
        probablePhoneNumber = potentialPhoneNumber
        puts "Phone number (probably) detected: #{probablePhoneNumber}"
      else
        #Send a message to the channel stating that a phone number wasn't found
        postMessage(params[:channel_name], "CALL command failed - the channel name does not contain an 11 digit number.")
        halt
      end
    end

    if params[:text] != '' #Get my number
      myPotentialPhoneNumber = params[:text]
    else
      myPotentialPhoneNumber = settings.myMobileNumber
    end

    if myPotentialPhoneNumber.length == 11
      # Call from Twilio - my phone first
      myCurrentPhoneNumber = myPotentialPhoneNumber
      puts "Dialing #{myCurrentPhoneNumber}"
      #Post to Slack
      postMessage(params[:channel_name], "Calling you at #{myCurrentPhoneNumber}.")
      #Dial my number, and make sure it connects
      startConference(probablePhoneNumber, settings.twilioSecondOutsideNumber, myCurrentPhoneNumber)

      #Wait for the channel to be created. For now, we'll just sleep
      sleep 5
      i = 0
      while i < 11 do #wait 11 seconds before trying not to do the second call. Note: Conference is marked as in-progress after 17 seconds?
                      #Turns out the call went to voicemail, which was marked as in progress. This complicates things. Timeout
        puts "Waiting. i = #{i}"
        sleep 1
        conferenceListStatus = @client.account.conferences.list({
          :status => "in-progress",
          :friendly_name => "#{probablePhoneNumber}"}).each do |conference|
            puts "Found in-progress conference - calling the second number"
            postMessage(params[:channel_name], "You answered (probably). Calling the recipient at #{probablePhoneNumber}.")
            #Once connected, dial the other number and connect them
            puts "Now doing joinConference(#{probablePhoneNumber}, #{settings.twilioOutsideNumber})"
            joinConference(probablePhoneNumber, settings.twilioOutsideNumber)
            #Post to Slack again (twilio-status)
            postMessage("twilio-status", "Made a call between caller at #{myCurrentPhoneNumber} and recipient at #{probablePhoneNumber}.")
            i = 20
            break
        end
        i +=1
      end
      puts "conferenceListStatus: #{conferenceListStatus}"
      # joinConference(probablePhoneNumber, settings.twilioOutsideNumber)

    else
      #Send a message to the channel stating that a phone number wasn't found
      postMessage(params[:channel_name], "CALL command failed - '#{myPotentialPhoneNumber}' number is not 11 digits. Try /callfrom")
      halt
    end

    #puts "Twiml = http://#{settings.thisHostNameorIP}:#{settings.port}/slackilio/outgoingconferenceroom?room=#{probablePhoneNumber}"
  end
  #@client = Twilio::REST::Client.new settings.twilioAccountSID, settings.twilioAuthToken
  #Once the call is over, post post the recording/'voicemail' url to Slack (it may be posted already)
end


post '/slackilio/startconferenceroom' do
  #p params
  #room = params[:room]
  content_type 'text/xml'
  "<?xml version='1.0' encoding='UTF-8'?><Response><Say>Connecting</Say><Dial><Conference record='record-from-start' beep='true' startConferenceOnEnter='true' endConferenceOnExit='true'>#{params[:room]}</Conference></Dial></Response>"
end


post '/slackilio/outgoingconferenceroom' do
  #p params
  #room = params[:room]
  content_type 'text/xml'
  "<?xml version='1.0' encoding='UTF-8'?><Response><Say></Say><Dial><Conference record='record-from-start' beep='false' waitUrl='' startConferenceOnEnter='true' endConferenceOnExit='true'>#{params[:room]}</Conference></Dial></Response>"
#  "<?xml version='1.0' encoding='UTF-8'?><Response><Say>Connecting</Say><Dial><Conference beep='true' endConferenceOnExit='false'>#{params[:room]}</Conference></Dial></Response>"
end


post '/slackilio/callstatus' do
  puts "Request received on callstatus"
  p params

  #Example completed post:
  ##{"Called"=>"+18445551212", "ToState"=>"", "CallerCountry"=>"US",
  #  "Direction"=>"inbound", "Timestamp"=>"Sun, 08 Nov 2015 18:49:31 +0000",
  #  "CallbackSource"=>"call-progress-events", "CallerState"=>"NC", "ToZip"=>"",
  #  "SequenceNumber"=>"0", "CallSid"=>"CA7b9df41d0dec66g49fafebe844105ab4",
  #  "To"=>"+18445551212", "CallerZip"=>"28301", "CallerName"=>"FAYETTEVILL  NC",
  #  "ToCountry"=>"US", "ApiVersion"=>"2010-04-01", "CalledZip"=>"", "CalledCity"=>"",
  #  "CallStatus"=>"completed", "Duration"=>"1", "From"=>"+19105551212", "CallDuration"=>"17",
  #  "AccountSid"=>"AD7a7689e51c69622e578c0e65690c9b5e", "CalledCountry"=>"US",
  #  "CallerCity"=>"FAYETTEVILLE", "Caller"=>"+19105551212", "FromCountry"=>"US",
  #  "ToCity"=>"", "FromCity"=>"FAYETTEVILLE", "CalledState"=>"", "FromZip"=>"28301", "FromState"=>"NC"}

  if params[:CallStatus] == "completed"
    if params[:number] #if '?number' is specified (the recipient) post to the the correct channel
      puts "sanitize_number(params[:number]) #{sanitize_number(params[:number])}. params[:number]: #{params[:number]}"
      postMessage("sms#{sanitize_number(params[:number])}", "**New #{params[:Duration]}min recording** from #{params[:number]}.\nRecording link: #{params[:RecordingUrl]}.wav")
    else #channel not specified. must be an incoming call. Post to Twilio-status
      puts "?number not specified. must be an incoming call."
      if params[:RecordingUrl]
        postMessage("twilio-status", "**New #{params[:Duration]}min recording** from #{params[:number]} (#{params[:Caller]}, #{params[:CallerName]}).\nRecording link: #{params[:RecordingUrl]}.wav")
      else
        postMessage("twilio-status", "**incoming call at #{params[:Timestamp]} from #{params[:From]} (#{params[:CallerName]})")
      end
    end
  else
    puts "Called /callstatus with a non-'completed' status"
      p params
      postMessage("twilio-status", "**Possible incoming call to #{params[:Called]} at #{params[:Timestamp]} from #{params[:From]} (#{params[:CallerName]})")
  end
#p params
end

# Caller is prompted to leave a voicemail while being recorded
post '/slackilio/voicemail' do
  puts "Recieved request to /slackilio/voicemail"

  # If RecordingUrl is specified, that means that a recording has been made on this call. Reasons: Complete voicemail, recorded call hung up, silence in the voicemail causing Twilio to end the recording, timeout over, causing Twilio to end the recording
  if params[:RecordingUrl] && params[:Digits] == "hangup"
    puts "Does have params[:RecordingUrl] && params[:Digits]"
    p params
    postMessage("twilio-status", "**New #{params[:Duration]}min recording** from #{params[:number]} (#{params[:Caller]}, #{params[:CallerName]}).\nRecording link: #{params[:RecordingUrl]}.wav")
    content_type 'text/xml'
    "<?xml version='1.0' encoding='UTF-8'?><Response><Say>Thank you, good bye</Say></Response>"
  elsif params[:DialCallStatus] == "completed"
    content_type 'text/xml'
    "<?xml version='1.0' encoding='UTF-8'?><Response><Dial><Conference beep='false' waitUrl='' startConferenceOnEnter='true' endConferenceOnExit='true'>NoMusicNoBeepRoom</Conference></Dial></Response>"
  else
    puts "Does NOT have params[:RecordingUrl] && params[:Digits]"
    p params
    content_type 'text/xml'
    "<?xml version='1.0' encoding='UTF-8'?><Response><Say>If this is urgent, call again. If it can wait, please send me an email</Say><Record action='http://#{settings.thisHostNameorIP}:#{settings.port}/slackilio/voicemailgoodbye' maxLength='120'/></Response>"
  end
end


# Once a voicemail is left, say Goodbye
post '/slackilio/voicemailgoodbye' do
  puts "Recieved request to /slackilio/voicemailgoodbye"
  p params

  content_type 'text/xml'
  "<?xml version='1.0' encoding='UTF-8'?><Response><Say>Thank you, good bye</Say></Response>"
end
