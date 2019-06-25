unit AdvErm;
{
DESCRIPTION:  Era custom Memory implementation
AUTHOR:       Alexander Shostak (aka Berserker aka EtherniDee aka BerSoft)
}

(***)  interface  (***)
uses
  Windows, SysUtils, Math, Utils, AssocArrays, DataLib, StrLib, Files,
  PatchApi, Core, GameExt, Erm, Stores, Heroes;

const
  SPEC_SLOT = -1;
  NO_SLOT   = -1;
  
  IS_TEMP   = 0;
  NOT_TEMP  = 1;
  
  IS_STR    = TRUE;
  OPER_GET  = TRUE;
  
  SLOTS_SAVE_SECTION  = 'Era.DynArrays_SN_M';
  ASSOC_SAVE_SECTION  = 'Era.AssocArray_SN_W';
  
  (* TParamModifier *)
  NO_MODIFIER     = 0;
  MODIFIER_ADD    = 1;
  MODIFIER_SUB    = 2;
  MODIFIER_MUL    = 3;
  MODIFIER_DIV    = 4;
  MODIFIER_CONCAT = 5;
  
  ERM_MEMORY_DUMP_FILE = GameExt.DEBUG_DIR + '\erm memory dump.txt';


type
  (* IMPORT *)
  TObjDict = DataLib.TObjDict;

  TErmCmdContext = packed record
    
  end; // .record TErmCmdContext

  TReceiverHandler = procedure;

  TVarType  = (INT_VAR, STR_VAR);
  
  TSlot = class
    ItemsType:  TVarType;
    IsTemp:     boolean;
    IntItems:   array of integer;
    StrItems:   array of string;
  end; // .class TSlot
  
  TAssocVar = class
    IntValue: integer;
    StrValue: string;
  end; // .class TAssocVar
  
  TServiceParam = packed record
    IsStr:          boolean;
    OperGet:        boolean;
    Dummy:          word;
    Value:          integer;
    StrValue:       pchar;
    ParamModifier:  integer;
  end; // .record TServiceParam

  PServiceParams  = ^TServiceParams;
  TServiceParams  = array [0..23] of TServiceParam;


function ExtendedEraService
(
      Cmd:        char;
      NumParams:  integer;
      Params:     PServiceParams;
  out Err:        pchar
): boolean; stdcall;


exports
  ExtendedEraService;

  
(***) implementation (***)


var
{O} NewReceivers: {O} TObjDict {OF TErmCmdHandler};

{O} Slots:      {O} AssocArrays.TObjArray {OF TSlot};
{O} AssocMem:   {O} AssocArrays.TAssocArray {OF TAssocVar};
    FreeSlotN:  integer = SPEC_SLOT - 1;
    ErrBuf:     array [0..255] of char;


procedure RegisterReceiver (ReceiverName: integer; ReceiverHandler: TReceiverHandler);
var
  OldReceiverHandler: TReceiverHandler;
   
begin
  OldReceiverHandler := NewReceivers[Ptr(ReceiverName)];

  if @OldReceiverHandler = nil then begin
    NewReceivers[Ptr(ReceiverName)] := @ReceiverHandler;
  end // .if
  else begin
    Erm.ShowMessage('Receiver "' + CHR(ReceiverName and $FF) + CHR(ReceiverName shr 8 and $FF) + '" is already registered!');
  end; // .else
end; // .procedure RegisterReceiver
    
procedure ModifyWithIntParam (var Dest: integer; var Param: TServiceParam);
begin
  case Param.ParamModifier of 
    NO_MODIFIER:  Dest := Param.Value;
    MODIFIER_ADD: Dest := Dest + Param.Value;
    MODIFIER_SUB: Dest := Dest - Param.Value;
    MODIFIER_MUL: Dest := Dest * Param.Value;
    MODIFIER_DIV: Dest := Dest div Param.Value;
  end; // .SWITCH Paramo.ParamModifier
end; // .procedure ModifyWithParam
    
function CheckCmdParams (Params: PServiceParams; const Checks: array of boolean): boolean;
var
  i:  integer;

begin
  {!} Assert(Params <> nil);
  {!} Assert(not ODD(Length(Checks)));
  result  :=  TRUE;
  i       :=  0;
  
  while result and (i <= High(Checks)) do begin
    result  :=
      (Params[i shr 1].IsStr  = Checks[i])  and
      (Params[i shr 1].OperGet = Checks[i + 1]);
    
    i :=  i + 2;
  end; // .while
end; // .function CheckCmdParams

function GetSlotItemsCount (Slot: TSlot): integer;
begin
  {!} Assert(Slot <> nil);
  if Slot.ItemsType = INT_VAR then begin
    result  :=  Length(Slot.IntItems);
  end // .if
  else begin
    result  :=  Length(Slot.StrItems);
  end; // .else
end; // .function GetSlotItemsCount

procedure SetSlotItemsCount (NewNumItems: integer; Slot: TSlot);
begin
  {!} Assert(NewNumItems >= 0);
  {!} Assert(Slot <> nil);
  if Slot.ItemsType = INT_VAR then begin
    SetLength(Slot.IntItems, NewNumItems);
  end // .if
  else begin
    SetLength(Slot.StrItems, NewNumItems);
  end; // .else
end; // .procedure SetSlotItemsCount

function NewSlot (ItemsCount: integer; ItemsType: TVarType; IsTemp: boolean): TSlot;
begin
  {!} Assert(ItemsCount >= 0);
  result            :=  TSlot.Create;
  result.ItemsType  :=  ItemsType;
  result.IsTemp     :=  IsTemp;
  
  SetSlotItemsCount(ItemsCount, result);
end; // .function NewSlot
  
function GetSlot (SlotN: integer; out {U} Slot: TSlot; out Error: string): boolean;
begin
  {!} Assert(Slot = nil);
  Slot    :=  Slots[Ptr(SlotN)];
  result  :=  Slot <> nil;
  
  if not result then begin
    Error :=  'Slot #' + SysUtils.IntToStr(SlotN) + ' does not exist.';
  end; // .if
end; // .function GetSlot 

function AllocSlot (ItemsCount: integer; ItemsType: TVarType; IsTemp: boolean): integer;
begin
  while Slots[Ptr(FreeSlotN)] <> nil do begin
    Dec(FreeSlotN);
    
    if FreeSlotN > 0 then begin
      FreeSlotN :=  SPEC_SLOT - 1;
    end; // .if
  end; // .while
  
  Slots[Ptr(FreeSlotN)] :=  NewSlot(ItemsCount, ItemsType, IsTemp);
  result                :=  FreeSlotN;
  Dec(FreeSlotN);
  
  if FreeSlotN > 0 then begin
    FreeSlotN :=  SPEC_SLOT - 1;
  end; // .if
end; // .function AllocSlot

function ExtendedEraService
(
      Cmd:        char;
      NumParams:  integer;
      Params:     PServiceParams;
  out Err:        pchar
): boolean;

var
{U} Slot:               TSlot;
{U} AssocVarValue:      TAssocVar;
    AssocVarName:       string;
    Error:              string;
    StrLen:             integer;
    NewSlotItemsCount:  integer;
    GameState:          TGameState;

begin
  Slot          :=  nil;
  AssocVarValue :=  nil;
  // * * * * * //
  result  :=  TRUE;
  Error   :=  'Invalid command parameters';
  
  case Cmd of 
    'M':
      begin
        case NumParams of
          // M; delete all slots
          0:
            begin
              Slots.Clear;
            end; // .case 0
          // M(Slot); delete specified slot
          1:
            begin
              result  :=
                CheckCmdParams(Params, [not IS_STR, not OPER_GET])  and
                (Params[0].Value <> SPEC_SLOT);
              
              if result then begin
                Slots.DeleteItem(Ptr(Params[0].Value));
              end; // .if
            end; // .case 1
          // M(Slot)/[?]ItemsCount; analog of SetLength/Length
          2:
            begin
              result  :=
                CheckCmdParams(Params, [not IS_STR, not OPER_GET])  and
                (not Params[1].IsStr)                               and
                (Params[1].OperGet or (Params[1].Value >= 0));

              if result then begin          
                if Params[1].OperGet then begin
                  Slot  :=  Slots[Ptr(Params[0].Value)];
                  
                  if Slot <> nil then begin
                    PINTEGER(Params[1].Value)^  :=  GetSlotItemsCount(Slot);
                  end // .if
                  else begin
                    PINTEGER(Params[1].Value)^  :=  NO_SLOT;
                  end; // .else
                  end // .if
                else begin
                  result  :=  GetSlot(Params[0].Value, Slot, Error);
                  
                  if result then begin
                    NewSlotItemsCount := GetSlotItemsCount(Slot);
                    ModifyWithIntParam(NewSlotItemsCount, Params[1]);
                    SetSlotItemsCount(NewSlotItemsCount, Slot);
                  end; // .if
                end; // .else
              end; // .if
            end; // .case 2
          // M(Slot)/(VarN)/[?](Value) or M(Slot)/?addr/(VarN)
          3:
            begin
              result  :=
                CheckCmdParams(Params, [not IS_STR, not OPER_GET])  and
                GetSlot(Params[0].Value, Slot, Error)               and
                (not Params[1].IsStr);
              
              if result then begin
                if Params[1].OperGet then begin
                  result  :=
                    (not Params[2].OperGet) and
                    (not Params[2].IsStr)   and
                    Math.InRange(Params[2].Value, 0, GetSlotItemsCount(Slot) - 1);
                  
                  if result then begin
                    if Slot.ItemsType = INT_VAR then begin
                      PPOINTER(Params[1].Value)^  :=  @Slot.IntItems[Params[2].Value];
                    end // .if
                    else begin
                      PPOINTER(Params[1].Value)^  :=  pointer(Slot.StrItems[Params[2].Value]);
                    end; // .else
                  end; // .if
                end // .if
                else begin
                  result  :=
                    (not Params[1].OperGet) and
                    (not Params[1].IsStr)   and
                    Math.InRange(Params[1].Value, 0, GetSlotItemsCount(Slot) - 1);
                  
                  if result then begin
                    if Params[2].OperGet then begin
                      if Slot.ItemsType = INT_VAR then begin
                        if Params[2].IsStr then begin
                          Windows.LStrCpy
                          (
                            Ptr(Params[2].Value),
                            Ptr(Slot.IntItems[Params[1].Value])
                          );
                        end // .if
                        else begin
                          PINTEGER(Params[2].Value)^  :=  Slot.IntItems[Params[1].Value];
                        end; // .else
                      end // .if
                      else begin
                        Windows.LStrCpy
                        (
                          Ptr(Params[2].Value),
                          pchar(Slot.StrItems[Params[1].Value])
                        );
                      end; // .else
                    end // .if
                    else begin
                      if Slot.ItemsType = INT_VAR then begin
                        if Params[2].IsStr then begin
                          if Params[2].ParamModifier = MODIFIER_CONCAT then begin
                            StrLen := SysUtils.StrLen(pchar(Slot.IntItems[Params[1].Value]));
                            
                            Windows.LStrCpy
                            (
                              Utils.PtrOfs(Ptr(Slot.IntItems[Params[1].Value]), StrLen),
                              Ptr(Params[2].Value)
                            );
                          end // .if
                          else begin
                            Windows.LStrCpy
                            (
                              Ptr(Slot.IntItems[Params[1].Value]),
                              Ptr(Params[2].Value)
                            );
                          end; // .else
                        end // .if
                        else begin
                          Slot.IntItems[Params[1].Value]  :=  Params[2].Value;
                        end; // .else
                      end // .if
                      else begin
                        if Params[2].Value = 0 then begin
                          Params[2].Value := integer(pchar(''));
                        end; // .if
                        
                        if Params[2].ParamModifier = MODIFIER_CONCAT then begin
                          Slot.StrItems[Params[1].Value] := Slot.StrItems[Params[1].Value] +
                                                            pchar(Params[2].Value);
                        end // .if
                        else begin
                          Slot.StrItems[Params[1].Value] := pchar(Params[2].Value);
                        end; // .else
                      end; // .else
                    end; // .else
                  end; // .if
                end; // .else
              end; // .if
            end; // .case 3
          4:
            begin
              result  :=  CheckCmdParams
              (
                Params,
                [
                  not IS_STR,
                  not OPER_GET,
                  not IS_STR,
                  not OPER_GET,
                  not IS_STR,
                  not OPER_GET,
                  not IS_STR,
                  not OPER_GET
                ]
              ) and
              (Params[0].Value >= SPEC_SLOT)                        and
              (Params[1].Value >= 0)                                and
              Math.InRange(Params[2].Value, 0, ORD(High(TVarType))) and
              ((Params[3].Value = IS_TEMP) or (Params[3].Value = NOT_TEMP));
              
              if result then begin
                if Params[0].Value = SPEC_SLOT then begin
                  Erm.v[1]  :=  AllocSlot
                  (
                    Params[1].Value, TVarType(Params[2].Value), Params[3].Value = IS_TEMP
                  );
                end // .if
                else begin
                  Slots[Ptr(Params[0].Value)] :=  NewSlot
                  (
                    Params[1].Value, TVarType(Params[2].Value), Params[3].Value = IS_TEMP
                  );
                end; // .else
              end; // .if
            end; // .case 4
        else
          result  :=  FALSE;
          Error   :=  'Invalid number of command parameters';
        end; // .SWITCH NumParams
      end; // .case "M"
    'K':
      begin
        case NumParams of 
          // C(str)/?(len)
          2:
            begin
              result  :=  (not Params[0].OperGet) and (not Params[1].IsStr) and (Params[1].OperGet);
              
              if result then begin
                PINTEGER(Params[1].Value)^  :=  SysUtils.StrLen(pointer(Params[0].Value));
              end; // .if
            end; // .case 2
          // C(str)/(ind)/[?](strchar)
          3:
            begin
              result  :=
                (not Params[0].OperGet) and
                (not Params[1].IsStr)   and
                (not Params[1].OperGet) and
                (Params[1].Value >= 0)  and
                (Params[2].IsStr);
              
              if result then begin
                if Params[2].OperGet then begin
                  pchar(Params[2].Value)^     :=  PEndlessCharArr(Params[0].Value)[Params[1].Value];
                  pchar(Params[2].Value + 1)^ :=  #0;
                end // .if
                else begin
                  PEndlessCharArr(Params[0].Value)[Params[1].Value] :=  pchar(Params[2].Value)^;
                end; // .else
              end; // .if
            end; // .case 3
          4:
            begin
              result  :=
                (not Params[0].IsStr)   and
                (not Params[0].OperGet) and
                (Params[0].Value >= 0);
              
              if result and (Params[0].Value > 0) then begin
                Utils.CopyMem(Params[0].Value, pointer(Params[1].Value), pointer(Params[2].Value));
              end; // .if
            end; // .case 4
        else
          result  :=  FALSE;
          Error   :=  'Invalid number of command parameters';
        end; // .SWITCH NumParams
      end; // .case "K"
    'W':
      begin
        case NumParams of 
          // Clear all
          0:
            begin
              AssocMem.Clear;
            end; // .case 0
          // Delete var
          1:
            begin
              result  :=  not Params[0].OperGet;
              
              if result then begin
                if Params[0].IsStr then begin
                  AssocVarName  :=  pchar(Params[0].Value);
                end // .if
                else begin
                  AssocVarName  :=  SysUtils.IntToStr(Params[0].Value);
                end; // .else
                
                AssocMem.DeleteItem(AssocVarName);
              end; // .if
            end; // .case 1
          // Get/set var
          2:
            begin
              result  :=  not Params[0].OperGet;
              
              if result then begin
                if Params[0].IsStr then begin
                  AssocVarName  :=  pchar(Params[0].Value);
                end // .if
                else begin
                  AssocVarName  :=  SysUtils.IntToStr(Params[0].Value);
                end; // .else
                
                AssocVarValue :=  AssocMem[AssocVarName];
                
                if Params[1].OperGet then begin
                  if Params[1].IsStr then begin
                    if (AssocVarValue = nil) or (AssocVarValue.StrValue = '') then begin
                      pchar(Params[1].Value)^ :=  #0;
                    end // .if
                    else begin
                      Utils.CopyMem
                      (
                        Length(AssocVarValue.StrValue) + 1,
                        pointer(AssocVarValue.StrValue),
                        pointer(Params[1].Value)
                      );
                    end; // .else
                  end // .if
                  else begin
                    if AssocVarValue = nil then begin
                      PINTEGER(Params[1].Value)^  :=  0;
                    end // .if
                    else begin
                      PINTEGER(Params[1].Value)^  :=  AssocVarValue.IntValue;
                    end; // .else
                  end; // .else
                end // .if
                else begin
                  if AssocVarValue = nil then begin
                    AssocVarValue           :=  TAssocVar.Create;
                    AssocMem[AssocVarName]  :=  AssocVarValue;
                  end; // .if
                  
                  if Params[1].IsStr then begin
                    if Params[1].ParamModifier <> MODIFIER_CONCAT then begin
                      AssocVarValue.StrValue  :=  pchar(Params[1].Value);
                    end // .if
                    else begin
                      AssocVarValue.StrValue := AssocVarValue.StrValue + pchar(Params[1].Value);
                    end; // .else
                  end // .if
                  else begin
                    ModifyWithIntParam(AssocVarValue.IntValue, Params[1]);
                  end; // .else
                end; // .else
              end; // .if
            end; // .case 2
        else
          result  :=  FALSE;
          Error   :=  'Invalid number of command parameters';
        end; // .SWITCH
      end; // .case "W"
    'D':
      begin
        GetGameState(GameState);
        
        if GameState.CurrentDlgId = ADVMAP_DLGID then begin
          Erm.ExecErmCmd('UN:R1;');
        end // .if
        else if GameState.CurrentDlgId = TOWN_SCREEN_DLGID then begin
          Erm.ExecErmCmd('UN:R4;');
        end // .ELSEIF
        else if GameState.CurrentDlgId = HERO_SCREEN_DLGID then begin
          Erm.ExecErmCmd('UN:R3/-1;');
        end // .ELSEIF
        else if GameState.CurrentDlgId = HERO_MEETING_SCREEN_DLGID then begin
          Heroes.RedrawHeroMeetingScreen;
        end; // .ELSEIF
      end; // .case "D"
  else
    result  :=  FALSE;
    Error   :=  'Unknown command "' + Cmd +'".';
  end; // .SWITCH Cmd
  
  if not result then begin
    Utils.CopyMem(Length(Error) + 1, pointer(Error), @ErrBuf);
    Err := @ErrBuf;
  end; // .if
end; // .function ExtendedEraService

procedure OnBeforeErmInstructions (Event: PEvent); stdcall;
begin
  Slots.Clear;
  AssocMem.Clear;
end; // .procedure OnBeforeErmInstructions

procedure SaveSlots;
var
{U} Slot:     TSlot;
    SlotN:    integer;
    NumSlots: integer;
    NumItems: integer;
    StrLen:   integer;
    i:        integer;
  
begin
  SlotN :=  0;
  Slot  :=  nil;
  // * * * * * //
  NumSlots  :=  Slots.ItemCount;
  Stores.WriteSavegameSection(sizeof(NumSlots), @NumSlots, SLOTS_SAVE_SECTION);
  
  Slots.BeginIterate;
  
  while Slots.IterateNext(pointer(SlotN), pointer(Slot)) do begin
    Stores.WriteSavegameSection(sizeof(SlotN), @SlotN, SLOTS_SAVE_SECTION);
    Stores.WriteSavegameSection(sizeof(Slot.ItemsType), @Slot.ItemsType, SLOTS_SAVE_SECTION);
    Stores.WriteSavegameSection(sizeof(Slot.IsTemp), @Slot.IsTemp, SLOTS_SAVE_SECTION);
    
    NumItems  :=  GetSlotItemsCount(Slot);
    Stores.WriteSavegameSection(sizeof(NumItems), @NumItems, SLOTS_SAVE_SECTION);
    
    if (NumItems > 0) and not Slot.IsTemp then begin
      if Slot.ItemsType = INT_VAR then begin
        Stores.WriteSavegameSection
        (
          sizeof(integer) * NumItems,
          @Slot.IntItems[0], SLOTS_SAVE_SECTION
        );
      end // .if
      else begin
        for i:=0 to NumItems - 1 do begin
          StrLen  :=  Length(Slot.StrItems[i]);
          Stores.WriteSavegameSection(sizeof(StrLen), @StrLen, SLOTS_SAVE_SECTION);
          
          if StrLen > 0 then begin
            Stores.WriteSavegameSection(StrLen, pointer(Slot.StrItems[i]), SLOTS_SAVE_SECTION);
          end; // .if
        end; // .for
      end; // .else
    end; // .if
    
    SlotN :=  0;
    Slot  :=  nil;
  end; // .while
  
  Slots.EndIterate;
end; // .procedure SaveSlots

procedure SaveAssocMem;
var
{U} AssocVarValue:  TAssocVar;
    AssocVarName:   string;
    NumVars:        integer;
    StrLen:         integer;
  
begin
  AssocVarValue :=  nil;
  // * * * * * //
  NumVars :=  AssocMem.ItemCount;
  Stores.WriteSavegameSection(sizeof(NumVars), @NumVars, ASSOC_SAVE_SECTION);
  
  AssocMem.BeginIterate;
  
  while AssocMem.IterateNext(AssocVarName, pointer(AssocVarValue)) do begin
    StrLen  :=  Length(AssocVarName);
    Stores.WriteSavegameSection(sizeof(StrLen), @StrLen, ASSOC_SAVE_SECTION);
    Stores.WriteSavegameSection(StrLen, pointer(AssocVarName), ASSOC_SAVE_SECTION);
    
    Stores.WriteSavegameSection
    (
      sizeof(AssocVarValue.IntValue),
      @AssocVarValue.IntValue,
      ASSOC_SAVE_SECTION
    );
    
    StrLen  :=  Length(AssocVarValue.StrValue);
    Stores.WriteSavegameSection(sizeof(StrLen), @StrLen, ASSOC_SAVE_SECTION);
    Stores.WriteSavegameSection(StrLen, pointer(AssocVarValue.StrValue), ASSOC_SAVE_SECTION);
    
    AssocVarValue :=  nil;
  end; // .while
  
  AssocMem.EndIterate;
end; // .procedure SaveAssocMem

procedure OnSavegameWrite (Event: PEvent); stdcall;
begin
  SaveSlots;
  SaveAssocMem;
end; // .procedure OnSavegameWrite

procedure LoadSlots;
var
{U} Slot:       TSlot;
    SlotN:      integer;
    NumSlots:   integer;
    ItemsType:  TVarType;
    IsTempSlot: boolean;
    NumItems:   integer;
    StrLen:     integer;
    i:          integer;
    y:          integer;

begin
  Slot      :=  nil;
  NumSlots  :=  0;
  // * * * * * //
  Slots.Clear;
  Stores.ReadSavegameSection(sizeof(NumSlots), @NumSlots, SLOTS_SAVE_SECTION);
  
  for i:=0 to NumSlots - 1 do begin
    Stores.ReadSavegameSection(sizeof(SlotN), @SlotN, SLOTS_SAVE_SECTION);
    Stores.ReadSavegameSection(sizeof(ItemsType), @ItemsType, SLOTS_SAVE_SECTION);
    Stores.ReadSavegameSection(sizeof(IsTempSlot), @IsTempSlot, SLOTS_SAVE_SECTION);
    
    Stores.ReadSavegameSection(sizeof(NumItems), @NumItems, SLOTS_SAVE_SECTION);
    
    Slot              :=  NewSlot(NumItems, ItemsType, IsTempSlot);
    Slots[Ptr(SlotN)] :=  Slot;
    SetSlotItemsCount(NumItems, Slot);
    
    if not IsTempSlot and (NumItems > 0) then begin
      if ItemsType = INT_VAR then begin
        Stores.ReadSavegameSection
        (
          sizeof(integer) * NumItems,
          @Slot.IntItems[0],
          SLOTS_SAVE_SECTION
        );
      end // .if
      else begin
        for y:=0 to NumItems - 1 do begin
          Stores.ReadSavegameSection(sizeof(StrLen), @StrLen, SLOTS_SAVE_SECTION);
          SetLength(Slot.StrItems[y], StrLen);
          Stores.ReadSavegameSection(StrLen, pointer(Slot.StrItems[y]), SLOTS_SAVE_SECTION);
        end; // .for
      end; // .else
    end; // .if
  end; // .for
end; // .procedure LoadSlots

procedure LoadAssocMem;
var
{O} AssocVarValue:  TAssocVar;
    AssocVarName:   string;
    NumVars:        integer;
    StrLen:         integer;
    i:              integer;
  
begin
  AssocVarValue :=  nil;
  NumVars       :=  0;
  // * * * * * //
  AssocMem.Clear;
  Stores.ReadSavegameSection(sizeof(NumVars), @NumVars, ASSOC_SAVE_SECTION);
  
  for i:=0 to NumVars - 1 do begin
    AssocVarValue :=  TAssocVar.Create;
    
    Stores.ReadSavegameSection(sizeof(StrLen), @StrLen, ASSOC_SAVE_SECTION);
    SetLength(AssocVarName, StrLen);
    Stores.ReadSavegameSection(StrLen, pointer(AssocVarName), ASSOC_SAVE_SECTION);
    
    Stores.ReadSavegameSection
    (
      sizeof(AssocVarValue.IntValue),
      @AssocVarValue.IntValue,
      ASSOC_SAVE_SECTION
    );
    
    Stores.ReadSavegameSection(sizeof(StrLen), @StrLen, ASSOC_SAVE_SECTION);
    SetLength(AssocVarValue.StrValue, StrLen);
    Stores.ReadSavegameSection(StrLen, pointer(AssocVarValue.StrValue), ASSOC_SAVE_SECTION);
    
    if (AssocVarValue.IntValue <> 0) or (AssocVarValue.StrValue <> '') then begin
      AssocMem[AssocVarName]  :=  AssocVarValue; AssocVarValue  :=  nil;
    end // .if
    else begin
      SysUtils.FreeAndNil(AssocVarValue);
    end; // .else
  end; // .for
end; // .procedure LoadAssocMem

procedure OnSavegameRead (Event: PEvent); stdcall;
begin
  LoadSlots;
  LoadAssocMem;
end; // .procedure OnSavegameRead

(*function HookFindErm_NewReceivers (Hook: TLoHook; Context: PHookContext): integer; stdcall;
const
  FuncParseParams = $73FDDC; // int cdecl f (Mes& M)
  
var
  NumParams: integer;

begin
  if  then begin
    // M.c[0]=':';
    PCharByte(Context.EBP - $8C])^ := ':';
    // Ind=M.i;
    PINTEGER(Context.EBP - $35C)^ := PINTEGER(Context.EBP - $318)^;
    // Num=GetNumAutoFl(&M);
    NumParams := PatchApi.Call(PatchApi.CDECL_, FuncParseParams, [Context.EBP - $35C]);
    // ToDoPo = 0
    PINTEGER(Context.EBP - $358)^ := 0;
    // ParSet = Num
    PINTEGER(Context.EBP - $3F8)^ := NumParams;
  end // .if
  else begin
    
  end; // .else
  // BREKA IS JUMP to JMP SHORT 0074B8C5
  result  :=  EXEC_DEFAULT;
end; // .function HookFindErm_NewReceivers*)

procedure DumpErmMemory (const DumpFilePath: string);
const
  ERM_CONTEXT_LEN = 300;
  
type
  TVarType          = (INT_VAR, FLOAT_VAR, STR_VAR, BOOL_VAR);
  PEndlessErmStrArr = ^TEndlessErmStrArr;
  TEndlessErmStrArr = array [0..MAXLONGINT div sizeof(Erm.TErmZVar) - 1] of TErmZVar;

var
{O} Buf:              StrLib.TStrBuilder;
    PositionLocated:  boolean;
    ErmContextHeader: string;
    ErmContext:       string;
    ScriptName:       string;
    LineN:            integer;
    ErmContextStart:  pchar;
    i:                integer;
    
  procedure WriteSectionHeader (const Header: string);
  begin
    if Buf.Size > 0 then begin
      Buf.Append(#13#10);
    end; // .if
    
    Buf.Append('> ' + Header + #13#10);
  end; // .procedure WriteSectionHeader
  
  procedure Append (const Str: string);
  begin
    Buf.Append(Str);
  end; // .procedure Append
  
  procedure LineEnd;
  begin
    Buf.Append(#13#10);
  end; // .procedure LineEnd
  
  procedure Line (const Str: string);
  begin
    Buf.Append(Str + #13#10);
  end; // .procedure Line
  
  function ErmStrToWinStr (const Str: string): string;
  begin
    result := StringReplace
    (
      StringReplace(Str, #13, '', [rfReplaceAll]), #10, #13#10, [rfReplaceAll]
    );
  end; // .function ErmStrToWinStr
  
  procedure DumpVars (const Caption, VarPrefix: string; VarType: TVarType; VarsPtr: pointer;
                      NumVars, StartInd: integer);
  var
    IntArr:        PEndlessIntArr;
    FloatArr:      PEndlessSingleArr;
    StrArr:        PEndlessErmStrArr;
    BoolArr:       PEndlessBoolArr;
    
    RangeStart:    integer;
    StartIntVal:   integer;
    StartFloatVal: single;
    StartStrVal:   string;
    StartBoolVal:  boolean;
    
    i:             integer;
    
    function GetVarName (RangeStart, RangeEnd: integer): string;
    begin
      result := VarPrefix + IntToStr(StartInd + RangeStart);
      
      if RangeEnd - RangeStart > 1 then begin
        result := result + '..' + VarPrefix + IntToStr(StartInd + RangeEnd - 1);
      end; // .if
      
      result := result + ' = ';
    end; // .function GetVarName
     
  begin
    {!} Assert(VarsPtr <> nil);
    {!} Assert(NumVars >= 0);
    if Caption <> '' then begin
      WriteSectionHeader(Caption); LineEnd;
    end; // .if

    case VarType of 
      INT_VAR:
        begin
          IntArr := VarsPtr;
          i      := 0;
          
          while i < NumVars do begin
            RangeStart  := i;
            StartIntVal := IntArr[i];
            Inc(i);
            
            while (i < NumVars) and (IntArr[i] = StartIntVal) do begin
              Inc(i);
            end; // .while
            
            Line(GetVarName(RangeStart, i) + IntToStr(StartIntVal));
          end; // .while
        end; // .case INT_VAR
      FLOAT_VAR:
        begin
          FloatArr := VarsPtr;
          i        := 0;
          
          while i < NumVars do begin
            RangeStart    := i;
            StartFloatVal := FloatArr[i];
            Inc(i);
            
            while (i < NumVars) and (FloatArr[i] = StartFloatVal) do begin
              Inc(i);
            end; // .while
            
            Line(GetVarName(RangeStart, i) + Format('%0.3f', [StartFloatVal]));
          end; // .while
        end; // .case FLOAT_VAR
      STR_VAR:
        begin
          StrArr := VarsPtr;
          i      := 0;
          
          while i < NumVars do begin
            RangeStart  := i;
            StartStrVal := pchar(@StrArr[i]);
            Inc(i);
            
            while (i < NumVars) and (pchar(@StrArr[i]) = StartStrVal) do begin
              Inc(i);
            end; // .while
            
            Line(GetVarName(RangeStart, i) + '"' + ErmStrToWinStr(StartStrVal) + '"');
          end; // .while
        end; // .case STR_VAR
      BOOL_VAR:
        begin
          BoolArr := VarsPtr;
          i       := 0;
          
          while i < NumVars do begin
            RangeStart   := i;
            StartBoolVal := BoolArr[i];
            Inc(i);
            
            while (i < NumVars) and (BoolArr[i] = StartBoolVal) do begin
              Inc(i);
            end; // .while
            
            Line(GetVarName(RangeStart, i) + IntToStr(byte(StartBoolVal)));
          end; // .while
        end; // .case BOOL_VAR
    else
      {!} Assert(FALSE);
    end; // .SWITCH 
  end; // .procedure DumpVars
  
  procedure DumpAssocVars;
  var
  {O} AssocList: {U} DataLib.TStrList {OF TAssocVar};
  {U} AssocVar:  TAssocVar;
      i:         integer;
  
  begin
    AssocList := DataLib.NewStrList(not Utils.OWNS_ITEMS, DataLib.CASE_SENSITIVE);
    AssocVar  := nil;
    // * * * * * //
    WriteSectionHeader('Associative vars'); LineEnd;
  
    with DataLib.IterateDict(AssocMem) do begin
      while IterNext do begin
        AssocList.AddObj(IterKey, IterValue);
      end; // .while
    end; // .with 
    
    AssocList.Sort;
    
    for i := 0 to AssocList.Count - 1 do begin
      AssocVar := AssocList.Values[i];
        
      if (AssocVar.IntValue <> 0) or (AssocVar.StrValue <> '') then begin
        Append(AssocList[i] + ' = ');
        
        if AssocVar.IntValue <> 0 then begin
          Append(IntToStr(AssocVar.IntValue));
          
          if AssocVar.StrValue <> '' then begin
            Append(', ');
          end; // .if
        end; // .if
        
        if AssocVar.StrValue <> '' then begin
          Append('"' + ErmStrToWinStr(AssocVar.StrValue) + '"');
        end; // .if
        
        LineEnd;
      end; // .if
    end; // .for
    // * * * * * //
    SysUtils.FreeAndNil(AssocList);
  end; // .procedure DumpAssocVars;
  
  procedure DumpSlots;
  var
  {O} SlotList:     {U} DataLib.TList {IF SlotInd: POINTER};
  {U} Slot:         TSlot;
      SlotInd:      integer;
      RangeStart:   integer;
      StartIntVal:  integer;
      StartStrVal:  string;
      i, k:         integer;
      
    function GetVarName (RangeStart, RangeEnd: integer): string;
    begin
      result := 'm' + IntToStr(SlotInd) + '[' + IntToStr(RangeStart);
      
      if RangeEnd - RangeStart > 1 then begin
        result := result + '..' + IntToStr(RangeEnd - 1);
      end; // .if
      
      result := result + '] = ';
    end; // .function GetVarName
     
  begin
    SlotList := DataLib.NewList(not Utils.OWNS_ITEMS);
    // * * * * * //
    WriteSectionHeader('Memory slots (dynamical arrays)');
    
    with DataLib.IterateObjDict(Slots) do begin
      while IterNext do begin
        SlotList.Add(IterKey);
      end; // .while
    end; // .with
    
    SlotList.Sort;
    
    for i := 0 to SlotList.Count - 1 do begin
      SlotInd := integer(SlotList[i]);
      Slot    := Slots[Ptr(SlotInd)];
      LineEnd; Append('; ');

      if Slot.IsTemp then begin
        Append('Temporal array (#');
      end // .if
      else begin
        Append('Permanent array (#');
      end; // .else
      
      Append(IntToStr(SlotInd) + ') of ');
      
      if Slot.ItemsType = AdvErm.INT_VAR then begin
        Line(IntToStr(Length(Slot.IntItems)) + ' integers');
        k := 0;
        
        while k < Length(Slot.IntItems) do begin
          RangeStart  := k;
          StartIntVal := Slot.IntItems[k];
          Inc(k);
          
          while (k < Length(Slot.IntItems)) and (Slot.IntItems[k] = StartIntVal) do begin
            Inc(k);
          end; // .while
          
          Line(GetVarName(RangeStart, k) + IntToStr(StartIntVal));
        end; // .while
      end // .if
      else begin
        Line(IntToStr(Length(Slot.StrItems)) + ' strings');
        k := 0;
        
        while k < Length(Slot.StrItems) do begin
          RangeStart  := k;
          StartStrVal := Slot.StrItems[k];
          Inc(k);
          
          while (k < Length(Slot.StrItems)) and (Slot.StrItems[k] = StartStrVal) do begin
            Inc(k);
          end; // .while
          
          Line(GetVarName(RangeStart, k) + '"' + ErmStrToWinStr(StartStrVal) + '"');
        end; // .while
      end; // .else
    end; // .for
    // * * * * * //
    SysUtils.FreeAndNil(SlotList);
  end; // .procedure DumpSlots

begin
  Buf := StrLib.TStrBuilder.Create;
  // * * * * * //
  WriteSectionHeader('ERA version: ' + GameExt.ERA_VERSION_STR);
  
  if ErmErrCmdPtr^ <> nil then begin
    ErmContextHeader := 'ERM context';
    PositionLocated  := ScriptMan.AddrToScriptNameAndLine(Erm.ErmErrCmdPtr^, ScriptName, LineN);
    
    if PositionLocated then begin
      ErmContextHeader := ErmContextHeader + ' in file "' + ScriptName + '" on line '
                          + IntToStr(LineN);
    end; // .if
    
    WriteSectionHeader(ErmContextHeader); LineEnd;

    try
      ErmContextStart := Erm.FindErmCmdBeginning(Erm.ErmErrCmdPtr^);
      ErmContext      := StrLib.ExtractFromPchar(ErmContextStart, ERM_CONTEXT_LEN) + '...';

      if StrLib.IsBinaryStr(ErmContext) then begin
        ErmContext := '';
      end; // .if
    except
      ErmContext := '';
    end; // .try

    Line(ErmContext);
  end; // .if
  
  WriteSectionHeader('Quick vars (f..t)'); LineEnd;
  
  for i := 0 to High(Erm.QuickVars^) do begin
    Line(CHR(ORD('f') + i) + ' = ' + IntToStr(Erm.QuickVars[i]));
  end; // .for
  
  DumpVars('Vars y1..y100', 'y', INT_VAR, @Erm.y[1], 100, 1);
  DumpVars('Vars y-1..y-100', 'y-', INT_VAR, @Erm.ny[1], 100, 1);
  DumpVars('Vars z-1..z-10', 'z-', STR_VAR, @Erm.nz[1], 10, 1);
  DumpVars('Vars e1..e100', 'e', FLOAT_VAR, @Erm.e[1], 100, 1);
  DumpVars('Vars e-1..e-100', 'e-', FLOAT_VAR, @Erm.ne[1], 100, 1);
  DumpAssocVars;
  DumpSlots;
  DumpVars('Vars f1..f1000', 'f', BOOL_VAR, @Erm.f[1], 1000, 1);
  DumpVars('Vars v1..v10000', 'v', INT_VAR, @Erm.v[1], 10000, 1);
  WriteSectionHeader('Hero vars w1..w200');
  
  for i := 0 to High(Erm.w^) do begin
    LineEnd;
    Line('; Hero #' + IntToStr(i));
    DumpVars('', 'w', INT_VAR, @Erm.w[i, 1], 200, 1);
  end; // .for
  
  DumpVars('Vars z1..z1000', 'z', STR_VAR, @Erm.z[1], 1000, 1);  
  Files.WriteFileContents(Buf.BuildStr, DumpFilePath);
  // * * * * * //
  SysUtils.FreeAndNil(Buf);
end; // .procedure DumpErmMemory

function Hook_DumpErmVars (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  DumpErmMemory(ERM_MEMORY_DUMP_FILE);
  Context.RetAddr := Core.Ret(0);
  result          := not Core.EXEC_DEF_CODE;
end; // .function Hook_DumpErmVars

procedure OnGenerateDebugInfo (Event: PEvent); stdcall;
begin
  DumpErmMemory(ERM_MEMORY_DUMP_FILE);
end; // .procedure OnGenerateDebugInfo

procedure OnBeforeWoG (Event: PEvent); stdcall;
begin
  (*Core.p.WriteLoHook($74B6B2, @HookFindErm_NewReceivers);*)
  
  (* Custom ERM memory dump *)
  Core.ApiHook(@Hook_DumpErmVars, Core.HOOKTYPE_BRIDGE, @Erm.ZvsDumpErmVars);
end; // .procedure OnBeforeWoG

begin
  (*NewReceivers  :=  DataLib.NewObjDict(Utils.OWNS_ITEMS);*)

  Slots     :=  AssocArrays.NewStrictObjArr(TSlot);
  AssocMem  :=  AssocArrays.NewStrictAssocArr(TAssocVar);
  
  GameExt.RegisterHandler(OnBeforeWoG,             'OnBeforeWoG');
  GameExt.RegisterHandler(OnBeforeErmInstructions, 'OnBeforeErmInstructions');
  GameExt.RegisterHandler(OnSavegameWrite,         'OnSavegameWrite');
  GameExt.RegisterHandler(OnSavegameRead,          'OnSavegameRead');
  GameExt.RegisterHandler(OnGenerateDebugInfo,     'OnGenerateDebugInfo');
end.
