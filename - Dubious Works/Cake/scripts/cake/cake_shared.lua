---@omw-context shared
--[[
    cake_shared.lua -- single source of truth for CAKE

    Generated from CAKE.esp / CAKE34.esp and from the node names in
    meshes/dbs/xbase_anim_dbs.nif. Nothing in this file is typed by hand, so
    the registry cannot drift from the plugins and skeleton it describes.

    RECORD SCHEME
    -------------
    Every wearable is a types.Miscellaneous pair:

        dbs_<thing>        the item that sits in the inventory
        dbs_<thing>_eq     the item that replaces it while worn

    Using the base record destroys it and creates the _eq record; using the
    _eq record converts it back. This is Sun's Dusk's backpack mechanism, and
    it is what makes CAKE non-invasive: a Miscellaneous item occupies no
    equipment slot at all, so unlike the OMWFW approach nothing has to be
    blocked from equipping and no helmet or pauldron is displaced. It also
    means the worn state is visible in the inventory as a distinct item with
    its own icon, rather than living only in script state.

    BOTH halves of the pair carry the same model. The _eq record's model is
    what gets attached as a VFX.

    BONES
    -----
    The DBS bones below are the twelve confirmed present in
    xbase_anim_dbs.nif. Each category also names a vanilla `fallback` bone
    for players running without that skeleton, because attaching to a missing
    bone is a silent no-show rather than an error.

    NO TAILS
    --------
    The plugins define 33 tail pairs and playergear.lua pointed all of them at
    `Bip01 tailsDBS`. That bone does not exist -- all 123 nodes of
    xbase_anim_dbs.nif were read and none is a tail -- so every tail failed
    hasBone and rendered nothing.

    Tails belong on the beast skeleton (xbase_animkna), which CAKE does not
    ship. They are therefore excluded from this registry rather than pointed
    at a substitute: a wrong bone is worse than an absent entry, because it
    looks like a working feature that silently does nothing. Re-add them by
    dropping the `tails` entry from EXCLUDED in tools/gen_cake_shared.py once
    a kna skeleton with a tail bone is in the package.
]]

local M = {}

M.version = 2

-- Suffix appended to a base record id to get its worn counterpart.
M.EQ_SUFFIX = '_eq'

-- ---------------------------------------------------------------------------
-- SKELETON
-- ---------------------------------------------------------------------------

-- Node names read directly out of meshes/dbs/xbase_anim_dbs.nif.
M.DBS_BONES = {
    ['Bip01 beltDBS'] = true,
    ['Bip01 R hipDBS'] = true,
    ['Bip01 L hipDBS'] = true,
    ['Bip01 chestDBS'] = true,
    ['Bip01 backpackDBS'] = true,
    ['Bip01 capeDBS'] = true,
    ['Bip01 mouthDBS'] = true,
    ['Bip01 eyesDBS'] = true,
    ['Bip01 earsDBS'] = true,
    ['Bip01 hornsDBS'] = true,
    ['Bip01 scarfDBS'] = true,
    ['Bip01 pendantDBS'] = true,
}

M.SKELETON = {
    auto    = { label = 'Auto-detect', probe = true },
    dbs     = { label = 'xbase_anim_dbs.nif', probe = false, bones = M.DBS_BONES },
    vanilla = { label = 'Vanilla skeleton only', probe = false, bones = {} },
}

M.DEFAULT_SKELETON = 'auto'

-- ---------------------------------------------------------------------------
-- CATEGORIES
-- ---------------------------------------------------------------------------
-- One vfxId per category, so categories sharing a bone do not evict each
-- other. `conflicts` names categories that cannot be worn together.

M.CATEGORIES = {
    lanterns  = {
        label        = 'Lanterns',
        vfxId        = 'cake_lanterns',
        bone         = 'Bip01 L hipDBS',
        boneFallback = 'Bip01 Pelvis',
        conflicts    = {  },
        count        = 46,
    },
    eyewear   = {
        label        = 'Eyewear',
        vfxId        = 'cake_eyewear',
        bone         = 'Bip01 eyesDBS',
        boneFallback = 'head',
        conflicts    = {  },
        count        = 20,
    },
    masks     = {
        label        = 'Masks',
        vfxId        = 'cake_masks',
        bone         = 'Bip01 mouthDBS',
        boneFallback = 'head',
        conflicts    = { 'smokes' },
        count        = 17,
    },
    scarves   = {
        label        = 'Scarves',
        vfxId        = 'cake_scarves',
        bone         = 'Bip01 scarfDBS',
        boneFallback = 'Bip01 Neck',
        conflicts    = {  },
        count        = 16,
    },
    belts     = {
        label        = 'Belts',
        vfxId        = 'cake_belts',
        bone         = 'Bip01 beltDBS',
        boneFallback = 'Bip01 Pelvis',
        conflicts    = {  },
        count        = 14,
    },
    bags      = {
        label        = 'Bags',
        vfxId        = 'cake_bags',
        bone         = 'Bip01 beltDBS',
        boneFallback = 'Bip01 Pelvis',
        conflicts    = {  },
        count        = 13,
    },
    smokes    = {
        label        = 'Smokes',
        vfxId        = 'cake_smokes',
        bone         = 'Bip01 mouthDBS',
        boneFallback = 'head',
        conflicts    = { 'masks' },
        count        = 2,
    },
    ears      = {
        label        = 'Ears',
        vfxId        = 'cake_ears',
        bone         = 'Bip01 earsDBS',
        boneFallback = 'head',
        conflicts    = {  },
        count        = 1,
    },
}

-- ---------------------------------------------------------------------------
-- ITEMS
-- ---------------------------------------------------------------------------
-- Keyed by the BASE record id (lowercase). `eq` is the worn record, `model`
-- is the mesh attached while worn.

M.ITEMS = {
    -- lanterns (46)
    ['dbs_glantern2']             = { eq = 'dbs_glantern2_eq', category = 'lanterns', model = 'l/light_de_lantern_02.nif' },
    ['dbs_glantern6']             = { eq = 'dbs_glantern6_eq', category = 'lanterns', model = 'l/light_de_lantern_06.nif' },
    ['dbs_glanterngrn']           = { eq = 'dbs_glanterngrn_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantgl_grn01.nif' },
    ['dbs_glanternred']           = { eq = 'dbs_glanternred_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantgl_red02.nif' },
    ['dbs_glanternyel']           = { eq = 'dbs_glanternyel_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantgl_yel01.nif' },
    ['dbs_lantern0aabdwrn']       = { eq = 'dbs_lantern0aabdwrn_eq', category = 'lanterns', model = 'oaab/l/dwrv_lantern.nif' },
    ['dbs_lanternpap1']           = { eq = 'dbs_lanternpap1_eq', category = 'lanterns', model = 'l/light_de_lantern_01.nif' },
    ['dbs_lanternpap10']          = { eq = 'dbs_lanternpap10_eq', category = 'lanterns', model = 'l/light_de_lantern_10.nif' },
    ['dbs_lanternpap11']          = { eq = 'dbs_lanternpap11_eq', category = 'lanterns', model = 'l/light_de_lantern_11.nif' },
    ['dbs_lanternpap14']          = { eq = 'dbs_lanternpap14_eq', category = 'lanterns', model = 'l/light_de_lantern_14.nif' },
    ['dbs_lanternpap5']           = { eq = 'dbs_lanternpap5_eq', category = 'lanterns', model = 'l/light_de_lantern_05.nif' },
    ['dbs_lanternpap7']           = { eq = 'dbs_lanternpap7_eq', category = 'lanterns', model = 'l/light_de_lantern_07.nif' },
    ['dbs_lanternpapblu1']        = { eq = 'dbs_lanternpapblu1_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantern_blu_01.nif' },
    ['dbs_lanternpapblu4']        = { eq = 'dbs_lanternpapblu4_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantern_blu_04.nif' },
    ['dbs_lanternpapgrn1']        = { eq = 'dbs_lanternpapgrn1_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantern_grn_01.nif' },
    ['dbs_lanternpapgrn4']        = { eq = 'dbs_lanternpapgrn4_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantern_grn_04.nif' },
    ['dbs_lanternpappur1']        = { eq = 'dbs_lanternpappur1_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantern_prp_01.nif' },
    ['dbs_lanternpappur4']        = { eq = 'dbs_lanternpappur4_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantern_prp_04.nif' },
    ['dbs_lanternpapyel1']        = { eq = 'dbs_lanternpapyel1_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantern_ylw_01.nif' },
    ['dbs_lanternpapyel4']        = { eq = 'dbs_lanternpapyel4_eq', category = 'lanterns', model = 'tr/l/tr_l_de_lantern_ylw_04.nif' },
    ['dbs_trindorilgrlan1']       = { eq = 'dbs_trindorilgrlan1_eq', category = 'lanterns', model = 'tr/l/tr_l_de_mhlant_gr_01.nif' },
    ['dbs_trindorilgrlan2']       = { eq = 'dbs_trindorilgrlan2_eq', category = 'lanterns', model = 'tr/l/tr_l_de_mhlant_gr_02.nif' },
    ['dbs_trindorilgrlan3']       = { eq = 'dbs_trindorilgrlan3_eq', category = 'lanterns', model = 'tr/l/tr_l_de_mhlant_gr_03.nif' },
    ['dbs_trindorillan1']         = { eq = 'dbs_trindorillan1_eq', category = 'lanterns', model = 'tr/l/tr_l_de_mhlant_whi_01.nif' },
    ['dbs_trindorillan2']         = { eq = 'dbs_trindorillan2_eq', category = 'lanterns', model = 'tr/l/tr_l_de_mhlant_whi_02.nif' },
    ['dbs_trindorillan3']         = { eq = 'dbs_trindorillan3_eq', category = 'lanterns', model = 'tr/l/tr_l_de_mhlant_whi_03.nif' },
    ['dbs_trindorilpurlan1']      = { eq = 'dbs_trindorilpurlan1_eq', category = 'lanterns', model = 'tr/l/tr_l_de_mhlant_pr_01.nif' },
    ['dbs_trindorilpurlan2']      = { eq = 'dbs_trindorilpurlan2_eq', category = 'lanterns', model = 'tr/l/tr_l_de_mhlant_pr_02.nif' },
    ['dbs_trindorilpurlan3']      = { eq = 'dbs_trindorilpurlan3_eq', category = 'lanterns', model = 'tr/l/tr_l_de_mhlant_pr_03.nif' },
    ['dbs_travlantern1']          = { eq = 'dbs_travlantern1_eq', category = 'lanterns', model = 'l/light_com_lantern_01.nif' },
    ['dbs_travlantern2']          = { eq = 'dbs_travlantern2_eq', category = 'lanterns', model = 'l/light_com_lantern_02.nif' },
    ['dbs_ash1']                  = { eq = 'dbs_ash1_eq', category = 'lanterns', model = 'l/light_ashl_lantern_01.nif' },
    ['dbs_ash2']                  = { eq = 'dbs_ash2_eq', category = 'lanterns', model = 'l/light_ashl_lantern_02.nif' },
    ['dbs_ash3']                  = { eq = 'dbs_ash3_eq', category = 'lanterns', model = 'l/light_ashl_lantern_03.nif' },
    ['dbs_ash4']                  = { eq = 'dbs_ash4_eq', category = 'lanterns', model = 'l/light_ashl_lantern_04.nif' },
    ['dbs_ash5']                  = { eq = 'dbs_ash5_eq', category = 'lanterns', model = 'l/light_ashl_lantern_05.nif' },
    ['dbs_ash6']                  = { eq = 'dbs_ash6_eq', category = 'lanterns', model = 'l/light_ashl_lantern_06.nif' },
    ['dbs_ash7']                  = { eq = 'dbs_ash7_eq', category = 'lanterns', model = 'l/light_ashl_lantern_07.nif' },
    ['dbs_cavelant']              = { eq = 'dbs_cavelant_eq', category = 'lanterns', model = 'oaab/l/cavern_lantern.nif' },
    ['dbs_colov2']                = { eq = 'dbs_colov2_eq', category = 'lanterns', model = 'pc/l/pc_col_lantern_02.nif' },
    ['dbs_colov3']                = { eq = 'dbs_colov3_eq', category = 'lanterns', model = 'pc/l/pc_col_lantern_03.nif' },
    ['dbs_colov4']                = { eq = 'dbs_colov4_eq', category = 'lanterns', model = 'pc/l/pc_col_lantern_04.nif' },
    ['dbs_colov5']                = { eq = 'dbs_colov5_eq', category = 'lanterns', model = 'pc/l/pc_col_lantern_05.nif' },
    ['dbs_orclan1']               = { eq = 'dbs_orclan1_eq', category = 'lanterns', model = 'sky/l/sky_lgt_orc_lantn_01.nif' },
    ['dbs_orclan2']               = { eq = 'dbs_orclan2_eq', category = 'lanterns', model = 'sky/l/sky_lgt_orc_lantn_02.nif' },
    ['dbs_woodlan']               = { eq = 'dbs_woodlan_eq', category = 'lanterns', model = 'sky/l/sky_light_nord_lat_04.nif' },

    -- eyewear (20)
    ['dbs_rv_blindfold1_h']       = { eq = 'dbs_rv_blindfold1_h_eq', category = 'eyewear', model = 'rv/blindfold1.nif' },
    ['dbs_rv_eyepatch1l_h']       = { eq = 'dbs_rv_eyepatch1l_h_eq', category = 'eyewear', model = 'rv/eyepatch1l.nif' },
    ['dbs_rv_eyepatch1r_h']       = { eq = 'dbs_rv_eyepatch1r_h_eq', category = 'eyewear', model = 'rv/eyepatch1r.nif' },
    ['dbs_rv_glasses1_h']         = { eq = 'dbs_rv_glasses1_h_eq', category = 'eyewear', model = 'rv/glasses1.nif' },
    ['dbs_rv_glasses1s_h']        = { eq = 'dbs_rv_glasses1s_h_eq', category = 'eyewear', model = 'rv/glasses1s.nif' },
    ['dbs_rv_glasses2_h']         = { eq = 'dbs_rv_glasses2_h_eq', category = 'eyewear', model = 'rv/glasses2.nif' },
    ['dbs_rv_glasses2s_h']        = { eq = 'dbs_rv_glasses2s_h_eq', category = 'eyewear', model = 'rv/glasses2s.nif' },
    ['dbs_rv_glasses3_h']         = { eq = 'dbs_rv_glasses3_h_eq', category = 'eyewear', model = 'rv/glasses3.nif' },
    ['dbs_rv_glasses4_h']         = { eq = 'dbs_rv_glasses4_h_eq', category = 'eyewear', model = 'rv/glasses4.nif' },
    ['dbs_rv_glasses4s_h']        = { eq = 'dbs_rv_glasses4s_h_eq', category = 'eyewear', model = 'rv/glasses4s.nif' },
    ['dbs_rv_goggles1_h']         = { eq = 'dbs_rv_goggles1_h_eq', category = 'eyewear', model = 'rv/goggles1.nif' },
    ['dbs_rv_goggles2_h']         = { eq = 'dbs_rv_goggles2_h_eq', category = 'eyewear', model = 'rv/goggles2.nif' },
    ['dbs_rv_goggles3_h']         = { eq = 'dbs_rv_goggles3_h_eq', category = 'eyewear', model = 'rv/goggles3.nif' },
    ['dbs_rv_goggles4_h']         = { eq = 'dbs_rv_goggles4_h_eq', category = 'eyewear', model = 'rv/goggles4.nif' },
    ['dbs_rv_goggles5_h']         = { eq = 'dbs_rv_goggles5_h_eq', category = 'eyewear', model = 'rv/goggles5.nif' },
    ['dbs_rv_goggles6_h']         = { eq = 'dbs_rv_goggles6_h_eq', category = 'eyewear', model = 'rv/goggles6.nif' },
    ['dbs_rv_goggles7_h']         = { eq = 'dbs_rv_goggles7_h_eq', category = 'eyewear', model = 'rv/goggles7.nif' },
    ['dbs_rv_goggles8_h']         = { eq = 'dbs_rv_goggles8_h_eq', category = 'eyewear', model = 'rv/goggles8.nif' },
    ['dbs_rv_lenses1_h']          = { eq = 'dbs_rv_lenses1_h_eq', category = 'eyewear', model = 'rv/lenses1.nif' },
    ['dbs_rv_lenses2_h']          = { eq = 'dbs_rv_lenses2_h_eq', category = 'eyewear', model = 'rv/lenses2.nif' },

    -- masks (17)
    ['dbs_rv_ashmask1_h']         = { eq = 'dbs_rv_ashmask1_h_eq', category = 'masks', model = 'rv/ashmask1.nif' },
    ['dbs_rv_ashmask2_h']         = { eq = 'dbs_rv_ashmask2_h_eq', category = 'masks', model = 'rv/ashmask2.nif' },
    ['dbs_rv_ashmask3_h']         = { eq = 'dbs_rv_ashmask3_h_eq', category = 'masks', model = 'rv/ashmask3.nif' },
    ['dbs_rv_daedramask1_h']      = { eq = 'dbs_rv_daedramask1_h_eq', category = 'masks', model = 'rv/daedramask1.nif' },
    ['dbs_rv_daedramask2_h']      = { eq = 'dbs_rv_daedramask2_h_eq', category = 'masks', model = 'rv/daedramask2.nif' },
    ['dbs_rv_daedramask3_h']      = { eq = 'dbs_rv_daedramask3_h_eq', category = 'masks', model = 'rv/daedramask3.nif' },
    ['dbs_rv_daedramask4_h']      = { eq = 'dbs_rv_daedramask4_h_eq', category = 'masks', model = 'rv/daedramask4.nif' },
    ['dbs_rv_facewrap1_h']        = { eq = 'dbs_rv_facewrap1_h_eq', category = 'masks', model = 'rv/facewrap1.nif' },
    ['dbs_rv_facewrap2_h']        = { eq = 'dbs_rv_facewrap2_h_eq', category = 'masks', model = 'rv/facewrap2.nif' },
    ['dbs_rv_facewrap3_h']        = { eq = 'dbs_rv_facewrap3_h_eq', category = 'masks', model = 'rv/facewrap3.nif' },
    ['dbs_rv_facewrap4_h']        = { eq = 'dbs_rv_facewrap4_h_eq', category = 'masks', model = 'rv/facewrap4.nif' },
    ['dbs_rv_facewrap5_h']        = { eq = 'dbs_rv_facewrap5_h_eq', category = 'masks', model = 'rv/facewrap5.nif' },
    ['dbs_rv_facewrap6_h']        = { eq = 'dbs_rv_facewrap6_h_eq', category = 'masks', model = 'rv/facewrap6.nif' },
    ['dbs_rv_facewrap7_h']        = { eq = 'dbs_rv_facewrap7_h_eq', category = 'masks', model = 'rv/facewrap7.nif' },
    ['dbs_rv_facewrap8_h']        = { eq = 'dbs_rv_facewrap8_h_eq', category = 'masks', model = 'rv/facewrap8.nif' },
    ['dbs_rv_orcishmask1_h']      = { eq = 'dbs_rv_orcishmask1_h_eq', category = 'masks', model = 'rv/orcishmask1.nif' },
    ['dbs_rv_orcishmask2_h']      = { eq = 'dbs_rv_orcishmask2_h_eq', category = 'masks', model = 'rv/orcishmask2.nif' },

    -- scarves (16)
    ['dbs_rv_scarf_01']           = { eq = 'dbs_rv_scarf_01_eq', category = 'scarves', model = 'rv/scarf1.nif' },
    ['dbs_rv_scarf_02']           = { eq = 'dbs_rv_scarf_02_eq', category = 'scarves', model = 'rv/scarf2.nif' },
    ['dbs_rv_scarf_03']           = { eq = 'dbs_rv_scarf_03_eq', category = 'scarves', model = 'rv/scarf3.nif' },
    ['dbs_rv_scarf_04']           = { eq = 'dbs_rv_scarf_04_eq', category = 'scarves', model = 'rv/scarf4.nif' },
    ['dbs_rv_scarf_05']           = { eq = 'dbs_rv_scarf_05_eq', category = 'scarves', model = 'rv/scarf5.nif' },
    ['dbs_rv_scarf_06']           = { eq = 'dbs_rv_scarf_06_eq', category = 'scarves', model = 'rv/scarf6.nif' },
    ['dbs_rv_scarf_07']           = { eq = 'dbs_rv_scarf_07_eq', category = 'scarves', model = 'rv/scarf7.nif' },
    ['dbs_rv_scarf_08']           = { eq = 'dbs_rv_scarf_08_eq', category = 'scarves', model = 'rv/scarf8.nif' },
    ['dbs_rv_scarf_09']           = { eq = 'dbs_rv_scarf_09_eq', category = 'scarves', model = 'rv/scarf9.nif' },
    ['dbs_rv_scarf_10']           = { eq = 'dbs_rv_scarf_10_eq', category = 'scarves', model = 'rv/scarf10.nif' },
    ['dbs_rv_scarf_11']           = { eq = 'dbs_rv_scarf_11_eq', category = 'scarves', model = 'rv/scarf11.nif' },
    ['dbs_rv_scarf_12']           = { eq = 'dbs_rv_scarf_12_eq', category = 'scarves', model = 'rv/scarf12.nif' },
    ['dbs_rv_scarf_13']           = { eq = 'dbs_rv_scarf_13_eq', category = 'scarves', model = 'rv/scarf13.nif' },
    ['dbs_rv_scarf_14']           = { eq = 'dbs_rv_scarf_14_eq', category = 'scarves', model = 'rv/scarf14.nif' },
    ['dbs_rv_scarf_15']           = { eq = 'dbs_rv_scarf_15_eq', category = 'scarves', model = 'rv/scarf15.nif' },
    ['dbs_rv_scarf_16']           = { eq = 'dbs_rv_scarf_16_eq', category = 'scarves', model = 'rv/scarf16.nif' },

    -- belts (14)
    ['dbs_aa_ubelt']              = { eq = 'dbs_aa_ubelt_eq', category = 'belts', model = 'frummyonda/fy_utilitybelt.nif' },
    ['dbs_cbelt1']                = { eq = 'dbs_cbelt1_eq', category = 'belts', model = 'belts/belt_common_1.nif' },
    ['dbs_cbelt2']                = { eq = 'dbs_cbelt2_eq', category = 'belts', model = 'belts/belt_common_2.nif' },
    ['dbs_cbelt3']                = { eq = 'dbs_cbelt3_eq', category = 'belts', model = 'belts/belt_common_3.nif' },
    ['dbs_cbelt4']                = { eq = 'dbs_cbelt4_eq', category = 'belts', model = 'belts/belt_common_4.nif' },
    ['dbs_cbelt5']                = { eq = 'dbs_cbelt5_eq', category = 'belts', model = 'belts/belt_common_5.nif' },
    ['dbs_erabinbelt']            = { eq = 'dbs_erabinbelt_eq', category = 'belts', model = 'belts/erabin.nif' },
    ['dbs_expbelt1']              = { eq = 'dbs_expbelt1_eq', category = 'belts', model = 'belts/belt_expensive_1.nif' },
    ['dbs_expbelt2']              = { eq = 'dbs_expbelt2_eq', category = 'belts', model = 'belts/belt_expensive_2.nif' },
    ['dbs_expbelt3']              = { eq = 'dbs_expbelt3_eq', category = 'belts', model = 'belts/belt_expensive_3.nif' },
    ['dbs_exqbelt']               = { eq = 'dbs_exqbelt_eq', category = 'belts', model = 'belts/belt_exquisite_1.nif' },
    ['dbs_extravbelt1']           = { eq = 'dbs_extravbelt1_eq', category = 'belts', model = 'belts/belt_extravagant_1.nif' },
    ['dbs_extravbelt2']           = { eq = 'dbs_extravbelt2_eq', category = 'belts', model = 'belts/belt_extravagant_2.nif' },
    ['dbs_hfirebelt']             = { eq = 'dbs_hfirebelt_eq', category = 'belts', model = 'belts/belt_hfire.nif' },

    -- bags (13)
    ['dbs_aa_fannypack']          = { eq = 'dbs_aa_fannypack_eq', category = 'bags', model = 'frummyonda/fy_fannypack_b.nif' },
    ['dbs_aa_fannypack_l']        = { eq = 'dbs_aa_fannypack_l_eq', category = 'bags', model = 'frummyonda/fy_fannypack_l.nif' },
    ['dbs_aa_fannypack_r']        = { eq = 'dbs_aa_fannypack_r_eq', category = 'bags', model = 'frummyonda/fy_fannypack_r.nif' },
    ['dbs_aa_fpkpch']             = { eq = 'dbs_aa_fpkpch_eq', category = 'bags', model = 'frummyonda/fy_fpackpouch.nif' },
    ['dbs_aa_fpktbg_l']           = { eq = 'dbs_aa_fpktbg_l_eq', category = 'bags', model = 'frummyonda/fy_fpktbg_l.nif' },
    ['dbs_aa_fpktbg_r']           = { eq = 'dbs_aa_fpktbg_r_eq', category = 'bags', model = 'frummyonda/fy_fpktbg_r.nif' },
    ['dbs_aa_satchel_f']          = { eq = 'dbs_aa_satchel_f_eq', category = 'bags', model = 'frummyonda/fy_satchel_f.nif' },
    ['dbs_aa_satchel_m']          = { eq = 'dbs_aa_satchel_m_eq', category = 'bags', model = 'frummyonda/fy_satchel_m.nif' },
    ['dbs_aa_thighbag_l']         = { eq = 'dbs_aa_thighbag_l_eq', category = 'bags', model = 'frummyonda/fy_thighbag_l.nif' },
    ['dbs_aa_thighbag_r']         = { eq = 'dbs_aa_thighbag_r_eq', category = 'bags', model = 'frummyonda/fy_thighbag_r.nif' },
    ['dbs_aa_waistbag']           = { eq = 'dbs_aa_waistbag_eq', category = 'bags', model = 'frummyonda/fy_waistbag_b.nif' },
    ['dbs_aa_waistbag_l']         = { eq = 'dbs_aa_waistbag_l_eq', category = 'bags', model = 'frummyonda/fy_waistbag_l.nif' },
    ['dbs_aa_waistbag_r']         = { eq = 'dbs_aa_waistbag_r_eq', category = 'bags', model = 'frummyonda/fy_waistbag_r.nif' },

    -- smokes (2)
    ['dbs_01cigar']               = { eq = 'dbs_01cigar_eq', category = 'smokes', model = 'ep/_01cigar.nif' },
    ['dbs_02cigar']               = { eq = 'dbs_02cigar_eq', category = 'smokes', model = 'ep/_0cigar.nif' },

    -- ears (1)
    ['dbs_1bear']                 = { eq = 'dbs_1bear_eq', category = 'ears', model = 'armoredtails/tailsnow_b.nif' },

}

-- ---------------------------------------------------------------------------
-- DERIVED
-- ---------------------------------------------------------------------------

-- Reverse index: worn record id -> base record id.
M.EQ_TO_BASE = {}
for baseId, entry in pairs(M.ITEMS) do
    M.EQ_TO_BASE[entry.eq] = baseId
end

M.allBones = {}
for _, cat in pairs(M.CATEGORIES) do
    if cat.bone then M.allBones[cat.bone] = true end
    M.allBones[cat.boneFallback] = true
end

-- ---------------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------------

---Entry for a base record id.
function M.get(recordId)
    if type(recordId) ~= 'string' then return nil end
    return M.ITEMS[recordId:lower()]
end

---Base record id for a worn record id, or nil if this is not a worn CAKE item.
---Uses the reverse index rather than string surgery: the old code did
---`id:sub(1, -4)`, which silently produced a non-existent id for anything
---whose naming did not match its assumption.
function M.baseOf(equippedId)
    if type(equippedId) ~= 'string' then return nil end
    return M.EQ_TO_BASE[equippedId:lower()]
end

---Worn record id for a base record id.
function M.eqOf(baseId)
    local entry = M.get(baseId)
    return entry and entry.eq or nil
end

function M.isBaseItem(recordId) return M.get(recordId) ~= nil end
function M.isWornItem(recordId) return M.baseOf(recordId) ~= nil end

---Category definition for either half of a pair.
function M.categoryOf(recordId)
    local entry = M.get(recordId) or M.get(M.baseOf(recordId))
    return entry and M.CATEGORIES[entry.category] or nil
end

return M
