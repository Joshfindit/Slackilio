Instructions are fairly minimal, assuming you know just enough about Ruby and Twilio to read the variable names, add settings, and get it running.

# The idea is this

In Slack, each number you contact will have a channel named `#sms#{number}`, such as `#sms18006927753`

To have an SMS conversation with this person, use the `/sms` slash command in their channel, such as `/sms Thank you for your input. I'm contacting the team now`

The recipient receives the SMS and replies as normal, which then shows up in the Slack channel.

When someone calls in, there is a notification in the Slack channel and the call is routed to the number you specify.

When someone on the team wants to call someone, they just go to the `#sms` channel, and use `/callfrom`. Twilio dials the number they specify, then calls out to the recipient, joining both in to a conference room automatically.


# You will need

- A server to run this on ([DigitalOcean](https://m.do.co/c/b8b974e3ad7e) is an easy choice)
- Your Twilio info (Number, Tokens)
- Your Slack info
- Time to set up the slash commands
- A number to forward to when doing calls (optional; you could do SMS only)

# Slack

- Create the following slash commands:
  - `/sms` # Takes input
  - `/call` # Does not take input
  - `/callfrom` # Takes input
- Route each command to the URL specified in `sinatra_server.rb`
- Add the tokens to `sinatra_server.rb`
- Test
