def get_driver(device)
	devpath = File.readlink("/sys/block/#{device}")
	raise "device #{device} not found" unless devpath
	parts = devpath.split(/\//)
	raise "bad link for #{device}" unless parts.shift == ".."
	raise "bad link for #{device}" unless parts.shift == "devices"
	raise "non-pci device #{device}" unless parts.first.start_with?("pci")
	driverlink = ["", "sys", "devices", parts.shift]
	driverlink.concat(parts.take_while { |p| p.match(/^[0-9a-f:.]+$/i) })
	driverlink << "driver"
	driverpath = File.readlink(driverlink.join("/"))
	raise "no driver for #{device}" unless driverpath
	return driverpath.split(/\//).last
end

class BlockInfo
	attr_accessor :device
	attr_accessor :disks
	def initialize(device)
		@device = device
		@disks = []
	end
	def driver
		@driver ||= get_driver(@device)
	end
	def vendor
		@vendor ||= File.read("/sys/block/#{device}/device/vendor").rstrip
	end
end

class DiskInfo
	attr_accessor :devid
	def initialize(devid)
		@devid = devid
	end
end

class DumbDiskInfo < DiskInfo
	attr_accessor :model
	attr_accessor :serial
	def initialize(devid, model, serial)
		super(devid)
		@model = model
		@serial = serial
	end
end

class SmartDiskInfo < DiskInfo
	attr_accessor :smartdev
	attr_accessor :smarttype
	def initialize(devid, smartdev, smarttype)
		super(devid)
		@smartdev = smartdev
		@smarttype = smarttype
		run_smartctl
	end
	def run_smartctl
		output = Facter::Util::Resolution.exec("smartctl -i -d #{@smarttype} /dev/#{@smartdev}")
		raise "missing smartctl?" unless output
		@model = output[/^Device Model: +(.*)/,1]
		@model = output[/^Product: +(.*)/,1] unless @model
		@serial = output[/^Serial [Nn]umber: +(.*)/,1]
		raise "model not found for #{devid}" unless @model
		raise "serial not found for #{devid}" unless @serial
	end
	def model
		run_smartctl unless @model
		return @model
	end
	def serial
		run_smartctl unless @serial
		return @serial
	end
end

def find_path(tool)
	minimal_path = ["/bin", "/sbin", "/usr/bin", "/usr/sbin"]
	(Facter.value(:path).split(":") + minimal_path).each do |dir|
		toolpath = "#{dir}/#{tool}"
		return toolpath if FileTest.executable?(toolpath)
	end
	nil
end

Facter.add(:twcli_path) do
	confine :kernel => "Linux"
	setcode { find_path("tw-cli") || find_path("tw_cli") }
end

def twcli_query(devicename, controller)
	twcli = Facter.value(:twcli_path)
	raise "no tw-cli tool found" unless twcli
	output = Facter::Util::Resolution.exec("#{twcli} /c#{controller} show drivestatus")
	raise "missing tw-cli?" unless output
	disks = []
	output.scan(/^p([0-9]+) /) do |port,|
		portpath = "/c#{controller}/p#{port}"
		Facter.debug "found port #{portpath}"
		model = Facter::Util::Resolution.exec("#{twcli} #{portpath} show model")[/ = (.*)/,1]
		raise "no model found for tw-cli #{portpath}" unless model
		serial = Facter::Util::Resolution.exec("#{twcli} #{portpath} show serial")[/ = (.*)/,1]
		raise "no serial found for tw-cli #{portpath}" unless model
		disks << DumbDiskInfo.new("#{devicename}_#{port}", model, serial)
	end
	return disks
end

if Facter.value(:kernel) == "Linux"
	blockdevs = []
	Dir.glob("/sys/block/sd?") do |path|
		begin
			device = BlockInfo.new(path[/sd./])
			blockdevs << device

			case device.driver
			when "ahci"
				device.disks << SmartDiskInfo.new(device.device, device.device, "ata")
			#when vendor == IBM-ESXS and driver == mptspi
			#	device.disks << SmartDiskInfo(device.device, device.device, "scsi")
			when "3w-9xxx"
				raise "unknown backing device #{device.device} for 3w-9xxx" unless device.device == "sda"
				# guessing that sda maps to twa0
				(0..127).each do |n|
					device.disks << SmartDiskInfo.new("#{device.device}_#{n}", "twa0", "3ware,#{n}")
				end
			when "megaraid_sas"
				(0..32).each do |n|
					begin
						device.disks << SmartDiskInfo.new("#{device.device}_#{n}", device.device, "megaraid,#{n}")
					rescue
					end
				end
				raise "no disks found for #{device.device}" unless device.disks
			when "3w-sas"
				raise "unknown backing device #{device.device} for 3w-sas" unless device.device == "sda"
				# guessing that sda maps to the first controller
				device.disks = twcli_query("sda", 0)
			# TODO: when vendor == LSILOGIC and driver == mptspi run smartctl on the sgN backing devices
			else
				Facter.debug "unknown driver #{device.driver} for #{device.device}"
			end
		rescue
			Facter.debug "exception while processing #{device.device}: " + $!.to_s
		end
	end
	Facter.add(:block_devices) { setcode { (blockdevs.collect(&:device)).join(",") } }
	blockdevs.each do |device|
		Facter.add("block_vendor_#{device.device}") { setcode { device.vendor } }
		Facter.add("block_driver_#{device.device}") { setcode { device.driver } }
		Facter.add("block_disks_#{device.device}") { setcode { (device.disks.collect(&:devid)).join(",") } }
		device.disks.each do |disk|
			Facter.add("disk_model_#{disk.devid}") { setcode { disk.model } }
			Facter.add("disk_serial_#{disk.devid}") { setcode { disk.serial } }
		end
	end
end
