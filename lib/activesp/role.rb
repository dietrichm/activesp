module ActiveSP
  
  class Role < Base
    
    include Caching
    include Util
    include InSite
    
    attr_reader :name
    
    def initialize(site, name)
      @site, @name = site, name
    end
    
    def attributes
      attributes_before_type_cast
    end
    cache :attributes
    
    def attributes_before_type_cast
      data.attributes.inject({}) { |h, (k, v)| h[k] = v.to_s ; h }
    end
    cache :attributes_before_type_cast
    
    def key
      encode_key("R", [@name])
    end
    
    def users
      call("UserGroup", "get_user_collection_from_role", "roleName" => @name).xpath("//spdir:User", NS).map do |row|
        attributes = row.attributes.inject({}) { |h, (k, v)| h[k] = v.to_s ; h }
        User.new(@site, attributes["LoginName"])
      end
    end
    cache :users
    
    def groups
      call("UserGroup", "get_group_collection_from_role", "roleName" => @name).xpath("//spdir:Group", NS).map do |row|
        attributes = row.attributes.inject({}) { |h, (k, v)| h[k] = v.to_s ; h }
        Group.new(@site, attributes["Name"])
      end
    end
    cache :groups
    
    def to_s
      "#<ActiveSP::Role name=#{@name}>"
    end
    
    alias inspect to_s
    
    def is_role?
      true
    end
    
  private
    
    def data
      call("UserGroup", "get_role_info", "roleName" => @name).xpath("//spdir:Role", NS).first
    end
    cache :data
    
  end
  
end
