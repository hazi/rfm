require 'forwardable'
module SaxChange
  
  #####  SAX HANDLER  #####
  
  # TODO: Find out why handler instance template_prefix attribute is empty, even when passing a template thru options.
  
  # A handler instance is created for each parsing run. The handler has several important functions:
  # 1. Receive callbacks from the sax/stream parsing engine (start_element, end_element, attribute...).
  # 2. Maintain a stack of cursors, growing & shrinking, throughout the parsing run.
  # 3. Maintain a Cursor instance throughout the parsing run.
  # 3. Hand over parser callbacks & data to the Cursor instance for refined processing.
  #
  # The handler instance is unique to each different parsing gem but inherits generic
  # methods from this Handler module. During each parsing run, the Hander module creates
  # a new instance of the spcified parer's handler class and runs the handler's main parsing method.
  # At the end of the parsing run the handler instance, along with it's newly parsed object,
  # is returned to the object that originally called for the parsing run (your script/app/whatever).
  # Remember: The template hash keys must be Strings, not Symbols.
  module Handler
  
    # We stick these methods in front of the specific handler class,
    # so they run before their namesake's in the Handler class.
    # TODO: Find a better place for this module, maybe its own file?
    module PrependMethods
    
      # We want this 'run_parser' to go before the specific handler's run_parser.
      def run_parser(io)
        SaxChange.log.info("#{self}#run_parser with:'#{io}'") if config[:log_parser]
        raise_if_bad_io(io)
        super # calls run_parser in backend-specific handler instance.
      end
      
      # We want SaxChange::Handler::SpecificParser.new to not hit the generic Handler.new.
      # By hijacking the 'self.new' method in front of the specific handler,
      # self.new won't get in a loop with Handler.new.
#       def self.prepended(other)
#         other.define_singleton_method(:new) do |*args|
#           allocate.tap {|h| h.send :initialize, *args}
#         end
#       end
    end # PrependMethods
  
    using Refinements
    
    # This might have to be done for each specific handler class,
    # but it seems to work just fine doing it once here.
    prepend Config
    
    extend Forwardable
  
    attr_accessor :stack, :template, :initial_object, :stack_debug, :default_class, :backend
    #def_delegators :'self.class', :label, :file, :setup, :backend_instance, :loaded
      
    def self.included(base)
      base.send :prepend, PrependMethods
      
      # Currently, this is done just in the main Handler class, and it seems to work.
      #base.send :prepend, Config
      
      #base.singleton_class.send :attr_accessor, :label, :file, :setup, :backend_instance, :loaded
    end
    
    def self.new(_backend=nil, _template=nil, _initial_object=nil,  **options)
      backend_handler_class = get_backend(_backend)
      #puts "#{self}.new with _backend:'#{_backend}', _template:'#{_template}', _initial_object:'#{_initial_object}', options:'#{options}'"
      backend_handler_class.new(_template, _initial_object, **options)
    end
      
    # Takes backend symbol and returns custom Handler class for specified backend.
    # TODO: Should this be private? Should it accept options?
    #def self.get_backend(parser_backend = config[:backend])
    def self.get_backend(_backend = nil)
      (_backend = decide_backend) unless _backend
      #puts "Handler.get_backend parser_backend: #{parser_backend}"
      if _backend.is_a?(String) || _backend.is_a?(Symbol)
        _backend = _backend.to_s
        #backend_handler_class = list_handlers.find {|h| h.label.to_s == _backend.to_s}
        class_name = _backend.split(/[\-_]/).map{|i| i.capitalize}.join.to_s + "Handler"
        puts "CLASS_NAME: #{class_name}"
        const_defined?(class_name) || require("saxchange/handler/#{_backend}_handler.rb")
        backend_handler_class = const_get(class_name)
      else
        backend_handler_class = _backend
      end
      
#       if ! backend_handler_class.loaded 
#         case
#           when backend_handler_class.setup.is_a?(Proc); backend_handler_class.setup.call
#           when backend_handler_class.setup.is_a?(String); backend_handler_class.eval(backend_handler_class.setup)
#         end
#         backend_handler_class.loaded = true
#       end
      
      backend_handler_class
#     rescue
#       raise "Could not load the backend parser '#{_backend}': #{$!}"
    end
  
    # Finds a loadable backend and returns its symbol.
    # TODO: Should this be private? Take options?
    #def self.decide_backend
    def self.decide_backend
      list_handlers.find do |fname|
        name = fname.gsub(/_handler\.rb/, '')
        Gem::Specification::find_all_by_name(name).any? || name == 'rexml'
      end
#     rescue
#       #puts "Handler.decide_backend raising #{$!}"
#       raise "The xml parser could not find a loadable backend library: #{$!}"
    end
    
    def self.list_handlers
      @handlers ||= Dir.entries(File.join(File.dirname(__FILE__), "handler/")).delete_if(){|f| !f[/[a-zA-Z0-9]/]}
    end
    
#     def self.list_handlers
#       @handlers ||= self.constants.collect do |c|
#         h = SaxChange::Handler.const_get(c)
#         #puts h.label rescue nil
#         h.respond_to?(:label) && h || nil
#       end.compact
#     end
   

    ###  Instance Methods  ###
  
    # TEMP: _template={} is experimental and maybe breaking. The default is _template=nil.
    def initialize(_template=nil, _initial_object=nil, **options)      
#       #puts "I AM Handler#initialize (#{self}) pre-delegation, with _template: #{_template}, _initial_object: #{_initial_object}, options: #{options},"
#       backend_parser_instance = case
#         when backend_instance.is_a?(Proc); backend_instance.call
#         when backend_instance.is_a?(String); eval(backend_instance)
#       end
#       __setobj__(backend_parser_instance) if backend_parser_instance
      
      @template = _template || config[:template]      
      #puts "I AM Handler#initialize (#{self}) post-delegation, with template: '#{@template}'"

      _initial_object ||= config[:initial_object] || (@template && @template['initial_object'])
      
      @initial_object = case
        when _initial_object.nil?; config[:default_class].new
        when _initial_object.is_a?(Class); _initial_object.new(**config) # added by wbr for v4
        when _initial_object.is_a?(String); eval(_initial_object)
        when _initial_object.is_a?(Symbol); self.class.const_get(_initial_object).new(**config) # added by wbr for v4
        when _initial_object.is_a?(Proc); _initial_object.call(self)
        else _initial_object
      end
      @stack = []
      @stack_debug=[]

      set_cursor Cursor.new('__TOP__', self, **options).process_new_element
    end
    
    # Call this from each backend 'run_parser' method.
    # The io.eof? method somehow causes exceptions within
    # the connection thread to bubble up properly.
    # Without the eof? method, nokogiri & ox mishandle the io
    # when the thread raises an exception. Try disabling this and see.
    def raise_if_bad_io(io)
      #SaxChange.log.info("#{self}.raise_if_bad_io status-of-io: '#{io.status}'") if config[:log_parser]
      if io.is_a?(IO) && (io.closed? || io.eof?)
        raise "#{self} was not able to execute 'run_parser'. The io object is closed or eof: #{io}"
      end
    end
  
    def result
      stack[0].object if stack[0].is_a? Cursor
    end
  
    def cursor
      stack.last
    end
  
    def set_cursor(args) # cursor_object
      if args.is_a? Cursor
        stack.push(args)
        #@stack_debug.push(args.dup.tap(){|c| c.handler = c.handler.object_id; c.parent = c.parent.tag})
      end
      cursor
    end
  
    def dump_cursor
      stack.pop
    end
  
    def top
      stack[0]
    end
  
    def transform(name)
      return name unless config[:tag_translation].is_a?(Proc)
      config[:tag_translation].call(name.to_s)
    end
  
    # Add a node to an existing element.
    def _start_element(tag, attributes=nil, *args)
      puts ["_START_ELEMENT", tag, attributes, args].to_yaml # if tag.to_s.downcase=='fmrestulset'
      tag = transform tag
      if attributes
        # This crazy thing transforms attribute keys to underscore (or whatever).
        #attributes = default_class[*attributes.collect{|k,v| [transform(k),v] }.flatten]
        # This works but downcases all attribute names - not good.
        attributes = config[:default_class].new.tap {|hash| attributes.each {|k, v| hash[transform(k)] = v}}
        # This doesn't work yet, but at least it wont downcase hash keys.
        #attributes = Hash.new.tap {|hash| attributes.each {|k, v| hash[transform(k)] = v}}
      end
      set_cursor cursor.receive_start_element(tag, attributes)
    end
  
    # Add attribute to existing element.
    def _attribute(name, value, *args)
      puts "Receiving attribute '#{name}' with value '#{value}'"
      name = transform name
      cursor.receive_attribute(name, value)
    end
  
    # Add 'content' attribute to existing element.
    def _text(value, *args)
      puts "Receiving text '#{value}'"
      #puts RUBY_VERSION_NUM
      if RUBY_VERSION_NUM > 1.8 && value.is_a?(String)
        #puts "Forcing utf-8"
        value.force_encoding('UTF-8')
      end
      # I think the reason this was here is no longer relevant, so I'm disabeling.
      return unless value[/[^\s]/]
      cursor.receive_attribute(config[:text_label], value)
    end
  
    # Close out an existing element.
    def _end_element(tag, *args)
      tag = transform tag
      puts "Receiving end_element '#{tag}'"
      cursor.receive_end_element(tag) and dump_cursor
    end
  
    def _doctype(*args)
      puts "Receiving doctype '#{args}'"
      (args = args[0].gsub(/"/, '').split) if args.size ==1
      _start_element('doctype', :value=>args)
      _end_element('doctype')
    end
  
  end # Handler
  


end # SaxChange