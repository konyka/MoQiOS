/// ACPI table structure definitions.

pub const RSDP = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,
    length: u32,
    xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,
};

pub const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

pub const Madt = extern struct {
    header: SdtHeader,
    local_apic_address: u32,
    flags: u32,
};

pub const MadtLapicEntry = extern struct {
    type: u8,
    length: u8,
    acpi_processor_id: u8,
    apic_id: u8,
    flags: u32,
};

pub const MadtIoapicEntry = extern struct {
    type: u8,
    length: u8,
    ioapic_id: u8,
    reserved: u8,
    ioapic_address: u32,
    gsi_base: u32,
};

pub const Mcfg = extern struct {
    header: SdtHeader,
    reserved: u64,
};

pub const McfgAllocation = extern struct {
    base_address: u64,
    segment_group: u16,
    start_bus: u8,
    end_bus: u8,
    reserved: u32,
};

pub const Fadt = extern struct {
    header: SdtHeader,
    firmware_ctrl: u32,
    dsdt: u32,
    reserved1: u8,
    preferred_pm_profile: u8,
    sci_int: u16,
    smi_cmd: u32,
    acpi_enable: u8,
    acpi_disable: u8,
    s4bios_req: u8,
    pstate_cnt: u8,
    pm1a_evt_blk: u32,
    pm1b_evt_blk: u32,
    pm1a_cnt_blk: u32,
    pm1b_cnt_blk: u32,
    pm2_cnt_blk: u32,
    pm_tmr_blk: u32,
    gpe0_blk: u32,
    gpe1_blk: u32,
};
