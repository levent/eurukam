#!/usr/local/bin/macruby
framework 'QuartzCore'
framework 'AVFoundation'
class NSTimer
  def self.scheduledTimerWithTimeInterval interval, repeats: repeat_flag, block: block
     self.scheduledTimerWithTimeInterval interval, 
                                  target: self, 
                                selector: 'executeBlockFromTimer:', 
                                userInfo: block, 
                                 repeats: repeat_flag
  end
  def self.timerWithTimeInterval interval, repeats: repeat_flag, block: block
    self.timerWithTimeInterval interval, 
                        target: self, 
                      selector: 'executeBlockFromTimer:', 
                      userInfo: block, 
                       repeats: repeat_flag
  end
  def self.executeBlockFromTimer aTimer
    blck = aTimer.userInfo
    time = aTimer.timeInterval
    blck[time] if blck
  end
end

class NSImage 
  def to_CGImage
    source = CGImageSourceCreateWithData(self.TIFFRepresentation, nil)
    maskRef = CGImageSourceCreateImageAtIndex(source, 0, nil)
  end
end

class NSColor 
  def toCGColor
    color_RGB = colorUsingColorSpaceName(NSCalibratedRGBColorSpace)
    components = [redComponent, greenComponent, blueComponent, alphaComponent]
    color_space = CGColorSpaceCreateWithName(KCGColorSpaceGenericRGB)
    color = CGColorCreate(color_space, components)
    CGColorSpaceRelease(color_space)
    color
  end
end

class NSView
  # set background like on IOS
  def background_color=(color)
    viewLayer = CALayer.layer
    viewLayer.backgroundColor = color.toCGColor
    self.wantsLayer = true # // view's backing store is using a Core Animation Layer
    self.layer = viewLayer
  end

  # helper to set nsview center like on IOS
  def center= (point)
    self.frameOrigin = [point.x-(self.frame.size.width/2), point.y-(self.frame.size.height/2)]
    self.needsDisplay = true
  end
end

DEFAULT_FRAMES_PER_SECOND = 5.0
class FaceMustafy
  def initialize
    @mustache = NSImage.alloc.initWithContentsOfURL NSURL.URLWithString("http://dl.dropbox.com/u/349788/mustache.png")
    @frameDuration = CMTimeMakeWithSeconds(1.0 / DEFAULT_FRAMES_PER_SECOND, 90000)
    window_setup    
    capture_session_setup
    #preview_layer = @window.contentView
    preview_layer = AVCaptureVideoPreviewLayer.alloc.initWithSession @captureSession
    preview_layer.videoGravity = AVLayerVideoGravityResizeAspectFill
    preview_layer.frame = @window.contentView.bounds
    preview_layer.connection.automaticallyAdjustsVideoMirroring = false
    preview_layer.connection.videoMirrored = true
    
    rootLayer = @window.contentView.layer
    rootLayer.backgroundColor = CGColorGetConstantColor(KCGColorBlack)
    rootLayer.addSublayer preview_layer
    
    @picture_output = AVCaptureStillImageOutput.new
    output_settings = {AVVideoCodecKey => AVVideoCodecJPEG}
    @picture_output.outputSettings = output_settings
    
    @captureSession.addOutput @picture_output if (@captureSession.canAddOutput @picture_output)
    
    videoConnection = connectionWithMediaType(AVMediaTypeVideo, fromConnections:@picture_output.connections) 
    videoConnection.automaticallyAdjustsVideoMirroring = false
    videoConnection.videoMirrored = true
    
    @captureSession.startRunning
    #@window.contentView.layer.addSublayer preview_layer
    
    take_picture = NSTimer.timerWithTimeInterval 5.0, repeats: false, block: -> time { self.capture_image }
    NSRunLoop.currentRunLoop.addTimer take_picture, forMode:NSDefaultRunLoopMode #NSEventTrackingRunLoopMode              
  end
  def connectionWithMediaType mediaType, fromConnections:connections
    connections.each do |connection|
      connection.inputPorts.each do |port|
        return connection if port.mediaType == mediaType
      end
    end
    nil
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

  def window_setup
    frame = [0.0, 0.0,640,480]
    @window = NSWindow.alloc.initWithContentRect frame, 
                                      styleMask: NSTitledWindowMask | NSClosableWindowMask,
                                        backing: NSBackingStoreBuffered,
                                          defer: false
    @window.delegate = self
    @window.makeKeyAndOrderFront nil
    @window.display    
    @window.center    
    @window.contentView.wantsLayer = true
  end

  def windowWillClose(sender); exit(1); end

  def capture_image
    img_connection = @picture_output.connectionWithMediaType AVMediaTypeVideo
    call_back = Proc.new do |img_buffer, error|
      exifAttachments = CMGetAttachment(img_buffer, KCGImagePropertyExifDictionary, nil)
      is_there_exif = exifAttachments ? "attachements: #{exifAttachments}" : "no attachements"
      NSLog(is_there_exif) 
      image_data = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation img_buffer
      
      formatDescription = CMSampleBufferGetFormatDescription(img_buffer)
      puts formatDescription.description #methods(true,true)
      ciImage = CIImage.imageWithData image_data
      detectorOptions = {CIDetectorAccuracy: CIDetectorAccuracyHigh }
      detector = CIDetector.detectorOfType CIDetectorTypeFace, context:nil, options:detectorOptions
      features = detector.featuresInImage(ciImage)
      Dispatch::Queue.main.async do
        features.each do |feature|
          if (feature.hasMouthPosition and feature.hasLeftEyePosition and feature.hasRightEyePosition)
            #mustache
            mustacheView = NSImageView.alloc.init
            mustacheView.image = @mustache
            mustacheView.imageFrameStyle = NSImageFrameNone
            mustacheView.imageScaling = NSScaleProportionally

            w = feature.bounds.size.width
            h = feature.bounds.size.height/5
            x = (feature.mouthPosition.x + (feature.leftEyePosition.x + feature.rightEyePosition.x)/2)/2 - w/2
            y = feature.mouthPosition.y
            mustacheView.frame = NSMakeRect(x, y, w, h)
            mustacheView.frameCenterRotation = Math.atan2(feature.rightEyePosition.y-feature.leftEyePosition.y,feature.rightEyePosition.x-feature.leftEyePosition.x)*180/Math::PI
            @window.contentView.addSubview(mustacheView)
          end
        end
      end
    end
    @picture_output.captureStillImageAsynchronouslyFromConnection img_connection, completionHandler:call_back
    end
  
  def run
    while true
      halfASecondFromNow = NSDate.alloc.initWithTimeIntervalSinceNow 0.5
      NSRunLoop.currentRunLoop.runUntilDate halfASecondFromNow
      halfASecondFromNow = nil        
    end
  end
end


NSApplicationLoad()
face_face = FaceMustafy.new
face_face.run
