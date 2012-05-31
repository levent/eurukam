
#!/usr/local/bin/macruby
framework 'QuartzCore'
framework 'AVFoundation'
framework 'Cocoa'
framework 'QTKit'

require 'rubygems'
require 'bundler/setup'
require 'nfc'
require 'rest_client'

class Capture
  attr_accessor :capture_view, :options

  def initialize()
    rect = [50, 50, 400, 300]
    win = NSWindow.alloc.initWithContentRect(rect,
                                             styleMask:NSBorderlessWindowMask,
                                             backing:2,
                                             defer:0)
    @capture_view = QTCaptureView.alloc.init

    @session = QTCaptureSession.alloc.init
    win.contentView = @capture_view

    device = QTCaptureDevice.defaultInputDeviceWithMediaType(QTMediaTypeVideo)
    ret = device.open(nil)
    raise "Device open error." if(ret != true)

    input = QTCaptureDeviceInput.alloc.initWithDevice(device)
    @session.addInput(input, error:nil)

    @capture_view.captureSession = @session
    @capture_view.delegate = self

    @session.startRunning
    true
  end

  def view(view, willDisplayImage:image)
    if(@flag == nil)
      @flag = true
      save(image)
      puts "Image saved"
      # NSApplication.sharedApplication.terminate(nil)
    end

    return image
  end

  def save(image)
    bitmapRep = NSBitmapImageRep.alloc.initWithCIImage(image)
    blob = bitmapRep.representationUsingType(NSJPEGFileType, properties:nil)
    blob.writeToFile(@options[:output], atomically:true)
    Dispatch::Queue.main.async {
      # Norbert, replace this
      RestClient.post('http://localhost:3000', :picture => File.new(@options[:output]), :auth_token => 'euruko_isight')
    }
  end
end

class NSColor
  def toCGColor
    # approach #2
    components = [redComponent, greenComponent, blueComponent, alphaComponent]
    color_space = CGColorSpaceCreateWithName(KCGColorSpaceGenericRGB)
    color = CGColorCreate(color_space, components)
    CGColorSpaceRelease(color_space)
    color
  end
end
class AVCaptureInput
  # Find the input port with the target media type
  def portWithMediaType media_type
    self.ports.select {|port| port.mediaType == media_type}.first
  end
end

class EurukoVideo
  RAND_MAX = 2147483647
  attr_accessor :window, :root_layer, :session, :video_preview_layers, :home_layer_rects, :spinningLayers
  
  def initialize
    @video_preview_layers = []
    @home_layer_rects = []      
  end

  def createWindowAndRootLayer
    # Create a screen-sized window
    main_display_bounds = NSRectToCGRect(NSScreen.mainScreen.frame)
    bounds = NSMakeRect(0, 0, main_display_bounds.size.width, main_display_bounds.size.height)
    @window = NSWindow.alloc.initWithContentRect bounds, 
                                      styleMask:NSBorderlessWindowMask, 
                                        backing:NSBackingStoreBuffered, 
                                          defer:false, 
                                         screen:NSScreen.mainScreen

    # Set the window level to floating
    windowLevel = NSFloatingWindowLevel
    @window.level = windowLevel

    # Make the content view layer-backed
    @window.contentView.wantsLayer = true
    # Grab the Core Animation layer
    @root_layer = @window.contentView.layer
    
    # Set its background color to opaque black
    colorspace = CGColorSpaceCreateDeviceRGB()
    blackColor = NSColor.colorWithDeviceRed(0.0, green:0.0, blue:0.0, alpha:1.0).toCGColor
    @root_layer.backgroundColor = blackColor
    CGColorRelease(blackColor)
    CFRelease(colorspace)

    # Show the window
    @window.makeKeyAndOrderFront nil
  end

  # Find capture devices that support video and/or muxed media
  def devicesThatCanProduceVideo
    devices = []
    ### map
    AVCaptureDevice.devices.each do |device|
      if (device.hasMediaType(AVMediaTypeVideo) || device.hasMediaType(AVMediaTypeMuxed))
        devices << device
      end
    end
    devices
  end

  # Compute frame for quadrant i of the input rectangle
  def rectForQuadrant idx, withinRect:rect 
    frame_wanted = rect.dup
    frame_wanted.size.width /= 2 
    frame_wanted.size.height /= 2
    
    case idx
      when 0
      when 1 # top right
        frame_wanted.origin.x += frame_wanted.size.width
      when 2 # bottom left 
        frame_wanted.origin.y += frame_wanted.size.height
      when 3 #  bottom right
        frame_wanted.origin.y += frame_wanted.size.height
        frame_wanted.origin.x += frame_wanted.size.width
    end
    

    # Make a 2-pixel border
    frame_wanted.origin.y += 2
    frame_wanted.origin.x += 2
    frame_wanted.size.width -= 4
    frame_wanted.size.height -= 4
    
    return frame_wanted
  end

  def capture_session_setup
    @captureSession = AVCaptureSession.new
    @captureSession.sessionPreset = AVCaptureSessionPresetPhoto
    
    # looking for Video device, if found add into the session
    videoDevice = AVCaptureDevice.defaultDeviceWithMediaType AVMediaTypeVideo
    videoDevice.lockForConfiguration nil
    if videoDevice 
      NSLog("got videoDevice")
      videoInput = AVCaptureDeviceInput.deviceInputWithDevice videoDevice, error:nil
      @captureSession.addInput videoInput if (@captureSession.canAddInput videoInput)
      return true
    end
    false
  end

  # Create 4 video preview layers per video device in a mirrored square, and
  # set up these squares left to right within the root layer
  def setup_video_wall
    error = nil
    # Find video devices
    devices = self.devicesThatCanProduceVideo
    devicesCount = devices.count
    currentDevice = 0

    return false if devicesCount == 0

    # For each video device
    devices.each do |device|
      # Create a device input with the device and add it to the session
      input = AVCaptureDeviceInput.deviceInputWithDevice device, error:error
      if (error)
        NSLog("deviceInputWithDevice: failed (#{error})")
        return false
      end
      @session.addInputWithNoConnections input

      # Find the video input port
      videoPort = input.portWithMediaType AVMediaTypeVideo
      NSLog("device count #{currentDevice}")
      
      # Set up its corresponding square within the root layer
      deviceSquareBounds = CGRectMake(0, 0, (@root_layer.bounds.size.width / 2), @root_layer.bounds.size.height / 2)


      deviceSquareBounds.origin.x = deviceSquareBounds.size.width / 2
      deviceSquareBounds.origin.y = deviceSquareBounds.size.height / 2
      # Create 4 video preview layers in the square
      # Create a video preview layer with the session
      videoPreviewLayer = AVCaptureVideoPreviewLayer.layerWithSessionWithNoConnection @session

      # Add it to the array
      @video_preview_layers.addObject videoPreviewLayer

      # Create a connection with the input port and the preview layer and add it to the session
      connection = AVCaptureConnection.connectionWithInputPort videoPort, videoPreviewLayer:videoPreviewLayer
      @session.addConnection connection

      # If the preview layer is at top-right (i=1) or bottom-left (i=2), flip it left-right
      # Compute the frame for the current layer
      # Each layer fills a quadrant of the square
      curLayerFrame = deviceSquareBounds
      CATransaction.begin
      
      # Disable implicit animations for this transaction
      CATransaction.setValue KCFBooleanTrue, forKey:KCATransactionDisableActions
      # Set the layer frame
      videoPreviewLayer.frame = curLayerFrame

      # Save the frame in an array for the "send_layers_home" animation
      @home_layer_rects.addObject curLayerFrame

      # We want the video content to always fill the entire layer regardless of the layer size,
      # so set video gravity to ResizeAspectFill
      videoPreviewLayer.setVideoGravity AVLayerVideoGravityResizeAspectFill

      # Add the preview layer to the root layer
      @root_layer.addSublayer videoPreviewLayer
      CATransaction.commit
      currentDevice+=1
    end
    true
  end

  # Spin the video preview layers
  def spin_the_layers
    if (@layers_spinning)
      CATransaction.begin
      @video_preview_layers.each do |layer|
        layer.removeAllAnimations
        # Set the animation duration
        CATransaction.setValue(5.0, forKey:KCATransactionAnimationDuration)
        # Change the layer's position to some random value within the root layer 
        layer.position = CGPointMake(@root_layer.bounds.size.width * rand(RAND_MAX)/RAND_MAX.to_f, 
                                     @root_layer.bounds.size.height * rand(RAND_MAX)/RAND_MAX.to_f)
        # Scale the layer 
        factor = rand(RAND_MAX) / RAND_MAX.to_f  * 2.0
        transform = CATransform3DMakeScale(factor, factor, 1.0)

        # Rotate the layer
        transform = CATransform3DRotate(transform, Math::acos(-1.0) * rand(RAND_MAX)/RAND_MAX.to_f, 
                                                                      rand(RAND_MAX)/RAND_MAX.to_f, 
                                                                      rand(RAND_MAX)/RAND_MAX.to_f, 
                                                                      rand(RAND_MAX)/RAND_MAX.to_f)

        # Apply the transform
        layer.transform = transform
      end
      CATransaction.commit
      # Schedule another animation in 2 seconds
      Dispatch::Queue.main.after(2.0){ self.spin_the_layers }
    end
  end

  # Reset the video preview layers
  def send_layers_home
    CATransaction.begin
    @video_preview_layers.each_with_index do |layer, idx|
      # Set the animation duration
      CATransaction.setValue(1.0, forKey:KCATransactionAnimationDuration)

      # Reset the layer's frame to initial values 
      homeRect = @home_layer_rects[idx]
      layer.frame = homeRect
      # Reset the layer's transform to identity
      layer.setTransform CATransform3DIdentity
    end
    CATransaction.commit
  end

  def configure
    # Create a screen-sized window and Core Animation layer
    self.createWindowAndRootLayer
    # Create a capture session
    @session = AVCaptureSession.alloc.init
    # Set the session preset
    @session.setSessionPreset AVCaptureSessionPreset640x480

    # still image output setup
    @picture_output = AVCaptureStillImageOutput.new
    output_settings = {AVVideoCodecKey => AVVideoCodecJPEG}
    @picture_output.outputSettings = output_settings
    puts "Session can add output: #{@session.canAddOutput @picture_output}"
    @session.addOutput @picture_output if (@session.canAddOutput @picture_output)

    # Create a wall of video out of the video capture devices on your Mac
    success = self.setup_video_wall
  end

  def connectionWithMediaType mediaType, fromConnections:connections
    connections.each do |connection|
      connection.inputPorts.each do |port|
        return connection if port.mediaType == mediaType
      end
    end
    nil
  end

  def capture_picture(rfid_uid)
    puts "capture_picture #{Time.now}"
    sleep 5
    CATransaction.begin
      CATransaction.setValue 0.5, forKey: 'animationDuration'
      # fade it out
      fadeAnimation = CABasicAnimation.animationWithKeyPath "opacity"
      fadeAnimation.toValue = 0.2
      fadeAnimation.timingFunction = CAMediaTimingFunction.functionWithName('easeIn') 
      @root_layer.addAnimation fadeAnimation, forKey:"fadeAnimation"
    CATransaction.commit

    options = {}
    options[:output] = "#{Time.now.strftime('%Y-%m-%d-%H%M%S')}_rfid_#{rfid_uid}.jpg"
    @app = self
    capture = Capture.new
    capture.options = options
    @app.delegate = capture
    @app.run
  end

  def run
    @session.startRunning
    @quit = false
    # trop = 0
    # keyboard_input_Queue = Dispatch::Queue.new("keyboard input queue")
    @session.startRunning

    while (!@quit)
      Dispatch::Queue.main.async {
        loop do
          puts "looping #{Time.now}"

          # Norbert, uncomment this
          # NFC.instance.find do |tag|
          #   TODO: get the uid in proper format
          #   capture_picture(tag.uid.join('-'))
          # end
          #
          # Norbert, comment this
          capture_picture('euruko')
          puts "tag found #{Time.now}"
          sleep 0.5
        end
      }
      puts "here"
      half_second_from_now = NSDate.alloc.initWithTimeIntervalSinceNow 0.5
      NSRunLoop.currentRunLoop.runUntilDate half_second_from_now
      half_second_from_now = nil
    end
    puts "Finishing #{Time.now}"
    NSLog("Quitting")
    # # go back to start position
    self.send_layers_home
    sleep(1.0)
    # # Stop running the capture session
    @session.stopRunning
    return true
  end
end

success = false

# In a command line applicaton, NSApplicationLoad is required to get an NSWindow to become key and forefront.
NSApplicationLoad()
wall = EurukoVideo.new
success = wall.configure
if success
  success = wall.run
end

