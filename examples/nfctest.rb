require 'rubygems'
require 'nfc'
# Find a tag
NFC.instance.find do |tag|
  # Print out the tag we find
  p tag
end
