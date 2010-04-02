module ActiveSP
  
  class List < Base
    
    include InSite
    extend Caching
    extend PersistentCaching
    include Util
    
    attr_reader :site, :id
    
    persistent { |site, id, *a| [site.connection, [:list, id]] }
    def initialize(site, id, title = nil, attributes_before_type_cast1 = nil, attributes_before_type_cast2 = nil)
      @site, @id = site, id
      @Title = title if title
      @attributes_before_type_cast1 = attributes_before_type_cast1 if attributes_before_type_cast1
      @attributes_before_type_cast2 = attributes_before_type_cast2 if attributes_before_type_cast2
    end
    
    def url
      # Dirty. Used to use RootFolder, but if you get the data from the bulk calls, RootFolder is the empty
      # string rather than what it should be. That's what you get with web services as an afterthought I guess.
      view_url = File.dirname(attributes["DefaultViewUrl"])
      result = URL(@site.url).join(view_url).to_s
      if File.basename(result) == "Forms" and dir = File.dirname(result) and dir.length > @site.url.length
        result = dir
      end
      result
    end
    cache :url
    
    def relative_url
      @site.relative_url(url)
    end
    
    def key
      encode_key("L", [@site.key, @id])
    end
    
    def Title
      data1["Title"].to_s
    end
    cache :Title
    
    def items(options = {})
      folder = options.delete(:folder)
      query = options.delete(:query)
      query = query ? { "query" => query } : {}
      no_preload = options.delete(:no_preload)
      options.empty? or raise ArgumentError, "unknown options #{options.keys.map { |k| k.inspect }.join(", ")}"
      query_options = Builder::XmlMarkup.new.QueryOptions do |xml|
        xml.Folder(folder.url) if folder
      end
      if no_preload
        view_fields = Builder::XmlMarkup.new.ViewFields do |xml|
          %w[FSObjType ID UniqueId ServerUrl].each { |f| xml.FieldRef("Name" => f) }
        end
        result = call("Lists", "get_list_items", { "listName" => @id, "viewFields" => viewFields, "queryOptions" => query_options }.merge(query))
        result.xpath("//z:row", NS).map do |row|
          attributes = clean_item_attributes(row.attributes)
          (attributes["FSObjType"][/1$/] ? Folder : Item).new(
            self,
            attributes["ID"],
            folder,
            attributes["UniqueId"],
            attributes["ServerUrl"]
          )
        end
      else
        begin
          result = call("Lists", "get_list_items", { "listName" => @id, "viewFields" => "<ViewFields></ViewFields>", "queryOptions" => query_options }.merge(query))
          result.xpath("//z:row", NS).map do |row|
            attributes = clean_item_attributes(row.attributes)
            (attributes["FSObjType"][/1$/] ? Folder : Item).new(
              self,
              attributes["ID"],
              folder,
              attributes["UniqueId"],
              attributes["ServerUrl"],
              attributes
            )
          end
        rescue Savon::SOAPFault => e
          if e.message[/lookup column threshold/]
            fields = self.fields.map { |f| f.name }
            split_factor = 2
            begin
              split_size = (fields.length + split_factor - 1) / split_factor
              parts = []
              split_factor.times do |i|
                lo = i * split_size
                hi = [(i + 1) * split_size, fields.length].min - 1
                view_fields = Builder::XmlMarkup.new.ViewFields do |xml|
                  fields[lo..hi].each { |f| xml.FieldRef("Name" => f) }
                end
                by_id = {}
                result = call("Lists", "get_list_items", { "listName" => @id, "viewFields" => view_fields, "queryOptions" => query_options }.merge(query))
                result.xpath("//z:row", NS).map do |row|
                  attributes = clean_item_attributes(row.attributes)
                  by_id[attributes["ID"]] = attributes
                end
                parts << by_id
              end
              parts[0].map do |id, attrs|
                parts[1..-1].each do |part|
                  attrs.merge!(part[id])
                end
                (attrs["FSObjType"][/1$/] ? Folder : Item).new(
                  self,
                  attrs["ID"],
                  folder,
                  attrs["UniqueId"],
                  attrs["ServerUrl"],
                  attrs
                )
              end
            rescue Savon::SOAPFault => e
              if e.message[/lookup column threshold/]
                split_factor += 1
                retry
              else
                raise
              end
            end
          else
            raise
          end
        end
      end
    end
    
    def item(name)
      query = Builder::XmlMarkup.new.Query do |xml|
        xml.Where do |xml|
          xml.Eq do |xml|
            xml.FieldRef(:Name => "FileLeafRef")
            xml.Value(name, :Type => "String")
          end
        end
      end
      items(:query => query).first
    end
    
    def /(name)
      item(name)
    end
    
    def fields
      data1.xpath("//sp:Field", NS).map do |field|
        attributes = clean_attributes(field.attributes)
        if attributes["ID"] && attributes["StaticName"]
          Field.new(self, attributes["ID"].downcase, attributes["StaticName"], attributes["Type"], @site.field(attributes["ID"].downcase), attributes)
        end
      end.compact
    end
    cache :fields, :dup => true
    
    def fields_by_name
      fields.inject({}) { |h, f| h[f.attributes["StaticName"]] = f ; h }
    end
    cache :fields_by_name, :dup => true
    
    def field(id)
      fields.find { |f| f.ID == id }
    end
    
    def content_types
      result = call("Lists", "get_list_content_types", "listName" => @id)
      result.xpath("//sp:ContentType", NS).map do |content_type|
        ContentType.new(@site, self, content_type["ID"], content_type["Name"], content_type["Description"], content_type["Version"], content_type["Group"])
      end
    end
    cache :content_types, :dup => true
    
    def content_type(id)
      content_types.find { |t| t.id == id }
    end
    
    def permission_set
      if attributes["InheritedSecurity"]
        @site.permission_set
      else
        PermissionSet.new(self)
      end
    end
    cache :permission_set
    
    def to_s
      "#<ActiveSP::List Title=#{self.Title}>"
    end
    
    alias inspect to_s
    
  private
    
    def data1
      call("Lists", "get_list", "listName" => @id).xpath("//sp:List", NS).first
    end
    cache :data1
    
    def attributes_before_type_cast1
      clean_attributes(data1.attributes)
    end
    cache :attributes_before_type_cast1
    
    def data2
      call("SiteData", "get_list", "strListName" => @id)
    end
    cache :data2
    
    def attributes_before_type_cast2
      element = data2.xpath("//sp:sListMetadata", NS).first
      result = {}
      element.children.each do |ch|
        result[ch.name] = ch.inner_text
      end
      result
    end
    cache :attributes_before_type_cast2
    
    def original_attributes
      attrs = attributes_before_type_cast1.merge(attributes_before_type_cast2).merge("BaseType" => attributes_before_type_cast1["BaseType"])
      type_cast_attributes(@site, nil, internal_attribute_types, attrs)
    end
    cache :original_attributes
    
    def internal_attribute_types
      @@internal_attribute_types ||= {
        "AllowAnonymousAccess" => GhostField.new("AllowAnonymousAccess", "Bool", false, true),
        "AllowDeletion" => GhostField.new("AllowDeletion", "Bool", false, true),
        "AllowMultiResponses" => GhostField.new("AllowMultiResponses", "Bool", false, true),
        "AnonymousPermMask" => GhostField.new("AnonymousPermMask", "Integer", false, true),
        "AnonymousViewListItems" => GhostField.new("AnonymousViewListItems", "Bool", false, true),
        "Author" => GhostField.new("Author", "InternalUser", false, true),
        "BaseTemplate" => GhostField.new("BaseTemplate", "Text", false, true),
        "BaseType" => GhostField.new("BaseType", "Text", false, true),
        "Created" => GhostField.new("Created", "StandardDateTime", false, true),
        "DefaultViewUrl" => GhostField.new("DefaultViewUrl", "Text", false, true),
        "Description" => GhostField.new("Description", "Text", false, false),
        "Direction" => GhostField.new("Direction", "Text", false, true),
        "DocTemplateUrl" => GhostField.new("DocTemplateUrl", "Text", false, true),
        "EmailAlias" => GhostField.new("EmailAlias", "Text", false, true),
        "EmailInsertsFolder" => GhostField.new("EmailInsertsFolder", "Text", false, true),
        "EnableAssignedToEmail" => GhostField.new("EnableAssignedToEmail", "Bool", false, true),
        "EnableAttachments" => GhostField.new("EnableAttachments", "Bool", false, true),
        "EnableMinorVersion" => GhostField.new("EnableMinorVersion", "Bool", false, true),
        "EnableModeration" => GhostField.new("EnableModeration", "Bool", false, true),
        "EnableVersioning" => GhostField.new("EnableVersioning", "Bool", false, true),
        "EventSinkAssembly" => GhostField.new("EventSinkAssembly", "Text", false, true),
        "EventSinkClass" => GhostField.new("EventSinkClass", "Text", false, true),
        "EventSinkData" => GhostField.new("EventSinkData", "Text", false, true),
        "FeatureId" => GhostField.new("FeatureId", "Text", false, true),
        "Flags" => GhostField.new("Flags", "Integer", false, true),
        "HasUniqueScopes" => GhostField.new("HasUniqueScopes", "Bool", false, true),
        "Hidden" => GhostField.new("Hidden", "Bool", false, true),
        "ID" => GhostField.new("ID", "Text", false, true),
        "ImageUrl" => GhostField.new("ImageUrl", "Text", false, true),
        "InheritedSecurity" => GhostField.new("InheritedSecurity", "Bool", false, true),
        "InternalName" => GhostField.new("InternalName", "Text", false, true),
        "ItemCount" => GhostField.new("ItemCount", "Integer", false, true),
        "LastDeleted" => GhostField.new("LastDeleted", "StandardDateTime", false, true),
        "LastModified" => GhostField.new("LastModified", "XMLDateTime", false, true),
        "LastModifiedForceRecrawl" => GhostField.new("LastModifiedForceRecrawl", "XMLDateTime", false, true),
        "MajorVersionLimit" => GhostField.new("MajorVersionLimit", "Integer", false, true),
        "MajorWithMinorVersionsLimit" => GhostField.new("MajorWithMinorVersionsLimit", "Integer", false, true),
        "MobileDefaultViewUrl" => GhostField.new("MobileDefaultViewUrl", "Text", false, true),
        "Modified" => GhostField.new("Modified", "StandardDateTime", false, true),
        "MultipleDataList" => GhostField.new("MultipleDataList", "Bool", false, true),
        "Name" => GhostField.new("Name", "Text", false, true),
        "Ordered" => GhostField.new("Ordered", "Bool", false, true),
        "Permissions" => GhostField.new("Permissions", "Text", false, true),
        "ReadSecurity" => GhostField.new("ReadSecurity", "Integer", false, true),
        "RequireCheckout" => GhostField.new("RequireCheckout", "Bool", false, true),
        "RootFolder" => GhostField.new("RootFolder", "Text", false, true),
        "ScopeId" => GhostField.new("ScopeId", "Text", false, true),
        "SendToLocation" => GhostField.new("SendToLocation", "Text", false, true),
        "ServerTemplate" => GhostField.new("ServerTemplate", "Text", false, true),
        "ShowUser" => GhostField.new("ShowUser", "Bool", false, true),
        "ThumbnailSize" => GhostField.new("ThumbnailSize", "Integer", false, true),
        "Title" => GhostField.new("Title", "Text", false, true),
        "ValidSecurityInfo" => GhostField.new("ValidSecurityInfo", "Bool", false, true),
        "Version" => GhostField.new("Version", "Integer", false, true),
        "WebFullUrl" => GhostField.new("WebFullUrl", "Text", false, true),
        "WebId" => GhostField.new("WebId", "Text", false, true),
        "WebImageHeight" => GhostField.new("WebImageHeight", "Integer", false, true),
        "WebImageWidth" => GhostField.new("WebImageWidth", "Integer", false, true),
        "WorkFlowId" => GhostField.new("WorkFlowId", "Text", false, true),
        "WriteSecurity" => GhostField.new("WriteSecurity", "Integer", false, true)
      }
    end
    
    def permissions
      result = call("Permissions", "get_permission_collection", "objectName" => @id, "objectType" => "List")
      rootsite = @site.rootsite
      result.xpath("//spdir:Permission", NS).map do |row|
        accessor = row["MemberIsUser"][/true/i] ? User.new(rootsite, row["UserLogin"]) : Group.new(rootsite, row["GroupName"])
        { :mask => Integer(row["Mask"]), :accessor => accessor }
      end
    end
    cache :permissions, :dup => true
    
  end
  
end
