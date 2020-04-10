unit Lodman;
{
DESCRIPTION:  LOD archives manager. Includes resource redirection support
AUTHOR:       Alexander Shostak (aka Berserker aka EtherniDee aka BerSoft)
BASED ON:     "Lods" plugin by Sav, WoG Sources by ZVS
}

(***)  interface  (***)
uses
  Windows, SysUtils, Math, Utils, Files, Core, Lists, AssocArrays, TypeWrappers, DataLib, Log, Json,
  StrUtils, GameExt, Heroes, Stores, EventMan;

const
  MAX_NUM_LODS  = 100;
  DEF_NUM_LODS  = 8;
  
  LODREDIR_SAVE_SECTION = 'Era.ResourceRedirections';

type
  (* IMPORT *)
  TString = TypeWrappers.TString;

  TGameVersion  = Heroes.ROE..Heroes.SOD_AND_AB;
  TLodType      = (LOD_SPRITE = 1, LOD_BITMAP = 2, LOD_WAV = 3);
  
  PLodTable = ^TLodTable;
  TLodTable = array [0..MAX_NUM_LODS - 1] of Heroes.TLod;

  TZvsAddLodToList  = function (LodInd: integer): integer; cdecl;
  
  PIndexes  = ^TIndexes;
  TIndexes  = array [0..MAX_NUM_LODS - 1] of integer;
  
  PLodIndexes = ^TLodIndexes;
  TLodIndexes = packed record
    NumLods:  integer;
    Indexes:  PIndexes;
  end; // .record TLodIndexes
  
  PLodTypes = ^TLodTypes;
  TLodTypes = packed record
    Table:    array [TLodType, TGameVersion] of TLodIndexes;
    Indexes:  array [TLodType, TGameVersion] of TIndexes;
  end; // .record TLodTypes


const
  ZvsAddLodToList:  TZvsAddLodToList  = Ptr($75605B);
  ZvsLodTable:      PLodTable         = Ptr($28077D0);
  ZvsLodTypes:      PLodTypes         = Ptr($79EFE0);


procedure RedirectFile (const OldFileName, NewFileName: string);
procedure GlobalRedirectFile (const OldFileName, NewFileName: string);
function  FindFileLod (const FileName: string; out LodPath: string): boolean;
function  FileIsInLod (const FileName: string; Lod: Heroes.PLod): boolean;
function  FindRedirection (const FileName: string; var {out} Redirected: string): boolean;
  

(***) implementation (***)


const
  GLOBAL_REDIRECTIONS_CONFIG_DIR         = 'Data\Redirections';
  GLOBAL_MISSING_REDIRECTIONS_CONFIG_DIR = GLOBAL_REDIRECTIONS_CONFIG_DIR + '\Missing';
  MUSIC_DIR                              = 'Mp3';

  REDIRECT_ONLY_MISSING         = true;
  REDIRECT_MISSING_AND_EXISTING = not REDIRECT_ONLY_MISSING;

var
{O} GlobalLodRedirs:  {O} AssocArrays.TAssocArray {OF TString};
{O} LodRedirs:        {O} AssocArrays.TAssocArray {OF TString};
{O} LodList:          Lists.TStringList;
    NumLods:          integer = DEF_NUM_LODS;
    RedirCritSection: Windows.TRTLCriticalSection;


procedure UnregisterLod (LodInd: integer);
var
{U} Table:        PLodIndexes;
{U} Indexes:      PIndexes;
    LodType:      TLodType;
    GameVersion:  TGameVersion;
    LocalNumLods: integer;
    
    LeftInd:      integer;
    i:            integer;
   
begin
  {!} Assert(Math.InRange(LodInd, 0, NumLods - 1), 'Lod index is out of allowed range: ' + IntToStr(LodInd));
  Table   :=  nil;
  Indexes :=  nil;
  // * * * * * //
  for LodType := Low(TLodType) to High(TLodType) do begin
    for GameVersion := Low(TGameVersion) to High(TGameVersion) do begin
      Table         :=  @ZvsLodTypes.Table[LodType, GameVersion];
      Indexes       :=  Table.Indexes;
      LocalNumLods  :=  Table.NumLods;
      
      LeftInd :=  0;
      i       :=  0;
      
      while i < LocalNumLods do begin
        if Indexes[i] <> LodInd then begin
          Indexes[LeftInd]  :=  Indexes[i];
          Inc(LeftInd);
        end;
        
        Inc(i);
      end;
      
      Table.NumLods :=  LeftInd;
    end; // .for
  end; // .for
  
  Dec(NumLods);
end; // .procedure UnregisterLod

procedure UnregisterDeadLods;
begin
  if not SysUtils.FileExists('Data\h3abp_sp.lod') then begin
    UnregisterLod(7);
  end;
  
  if not SysUtils.FileExists('Data\h3abp_bm.lod') then begin
    UnregisterLod(6);
  end;
  
  if not SysUtils.FileExists('Data\h3psprit.lod') then begin
    UnregisterLod(5);
  end;
  
  if not SysUtils.FileExists('Data\h3pbitma.lod') then begin
    UnregisterLod(4);
  end;
  
  if not SysUtils.FileExists('Data\h3ab_spr.lod') then begin
    UnregisterLod(3);
  end;
  
  if not SysUtils.FileExists('Data\h3ab_bmp.lod') then begin
    UnregisterLod(2);
  end;
  
  if not SysUtils.FileExists('Data\h3sprite.lod') then begin
    UnregisterLod(1);
  end;
  
  if not SysUtils.FileExists('Data\h3bitmap.lod') then begin
    UnregisterLod(0);
  end;
end; // .procedure UnregisterDeadLods

function FileIsInLod (const FileName: string; Lod: Heroes.PLod): boolean; 
begin
  {!} Assert(Lod <> nil);
  result  :=  false;
  
  if FileName <> '' then begin
    asm
      MOV ECX, Lod
      ADD ECX, 4
      PUSH FileName
      MOV EAX, $4FB100
      CALL EAX
      MOV result, AL
    end; // .asm
  end;
end; // .function FileIsInLod 

function FindFileLod (const FileName: string; out LodPath: string): boolean;
var
  Lod:  Heroes.PLod;
  i:    integer;
  
begin
  Lod :=  Utils.PtrOfs(ZvsLodTable, sizeof(Heroes.TLod) * (NumLods - 1));
  // * * * * * //
  result  :=  false;
  i       :=  NumLods - 1;
   
  while not result and (i >= 0) do begin
    result  :=  FileIsInLod(FileName, Lod);
    
    if not result then begin
      Lod :=  Utils.PtrOfs(Lod, -sizeof(Heroes.TLod));
      Dec(i);
    end;
  end;

  if result then begin
    LodPath :=  pchar(integer(Lod) + 8);
  end;
end; // .function FindFileLod

function FileIsInLods (const FileName: string): boolean;
var
  FoundLod: string;

begin
  result := FindFileLod(FileName, FoundLod);
end;

function FindRedirection (const FileName: string; var {out} Redirected: string): boolean;
var
{U} Redirection: TString;

begin
  Redirection := LodRedirs[FileName];
  // * * * * * //
  result := false;

  if Redirection = nil then begin
    Redirection := GlobalLodRedirs[FileName];
  end;

  if Redirection <> nil then begin
    Redirected := Redirection.Value;
    result     := true;
  end;
end; // .function FindRedirection

(* Loads global redirection rules from json configs *)
procedure LoadGlobalRedirectionConfig (const ConfigDir: string; RedirectOnlyMissing: boolean);
var
{O} Config:             TlkJsonObject;
    ResourceName:       string;
    WillBeRedirected:   boolean;
    ConfigFileContents: string;
    i:                  integer;

begin
  Config := nil;
  // * * * * * //
  with Files.Locate(ConfigDir + '\*.json', Files.ONLY_FILES) do begin
    while FindNext do begin
      if Files.ReadFileContents(ConfigDir + '\' + FoundName, ConfigFileContents) then begin
        Utils.CastOrFree(TlkJson.ParseText(ConfigFileContents), TlkJsonObject, Config);
        
        if Config <> nil then begin
          for i := 0 to Config.Count - 1 do begin
            ResourceName := Config.NameOf[i];

            if GlobalLodRedirs[ResourceName] = nil then begin
              WillBeRedirected := not RedirectOnlyMissing;

              if RedirectOnlyMissing then begin
                if AnsiEndsText(ResourceName, '.mp3') then begin
                  WillBeRedirected := not FileExists(MUSIC_DIR + '\' + ResourceName);
                end else begin
                  WillBeRedirected := not FileIsInLods(ResourceName);
                end;
              end;
              
              if WillBeRedirected then begin
                GlobalLodRedirs[ResourceName] := TString.Create(Config.getString(i));
              end;
            end; // .if
          end; // .for
        end else begin
          Core.NotifyError('Invalid json config: "' + ConfigDir + '\' + FoundName + '"');
        end; // .else
      end; // .if
    end; // .while
  end; // .with
  // * * * * * //
  FreeAndNil(Config);
end; // .procedure LoadGlobalRedirectionConfig

function Hook_LoadLods (Context: Core.PHookContext): LONGBOOL; stdcall;
var
  i: integer;
  
begin
  UnregisterDeadLods;
  
  with Files.Locate('Data\*.pac', Files.ONLY_FILES) do begin
    while FindNext do begin
      LodList.Add(FoundName);
    end;
  end;
  
  for i := LodList.Count - 1 downto 0 do begin
    Heroes.LoadLod(LodList[i], @ZvsLodTable[NumLods]);
    ZvsAddLodToList(NumLods);
    Inc(NumLods);
  end;

  result  :=  Core.EXEC_DEF_CODE;
end; // .function Hook_LoadLods

function Hook_FindFileInLod (Context: Core.PHookContext): LONGBOOL; stdcall;
var
  Redirected: string;

begin 
  if FindRedirection(ppchar(Context.EBP + $8)^, Redirected) then begin
    ppchar(Context.EBP + $8)^ := pchar(Redirected);
  end;
  
  result := Core.EXEC_DEF_CODE;
end;

function Hook_AfterLoadLods (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  LoadGlobalRedirectionConfig(GLOBAL_MISSING_REDIRECTIONS_CONFIG_DIR, REDIRECT_ONLY_MISSING);
  GameExt.FireEvent('OnAfterLoadLods', nil, 0);
  result := Core.EXEC_DEF_CODE;
end;

procedure RedirectFile (const OldFileName, NewFileName: string);
var
  Redirection:  TString;
   
begin
  {!} Windows.EnterCriticalSection(RedirCritSection);

  if NewFileName = '' then begin
    if OldFileName = '' then begin
      LodRedirs.Clear;
    end else begin
      LodRedirs.DeleteItem(OldFileName);
    end;
  end else begin
    Redirection := LodRedirs[OldFileName];
  
    if Redirection = nil then begin
      LodRedirs[OldFileName] := TString.Create(NewFileName);
    end else begin
      Redirection.Value := NewFileName;
    end;
  end; // .else
  
  {!} Windows.LeaveCriticalSection(RedirCritSection);
end; // .procedure RedirectFile

procedure GlobalRedirectFile (const OldFileName, NewFileName: string);
var
  Redirection:  TString;
   
begin
  {!} Windows.EnterCriticalSection(RedirCritSection);

  if NewFileName = '' then begin
    if OldFileName = '' then begin
      GlobalLodRedirs.Clear;
    end else begin
      GlobalLodRedirs.DeleteItem(OldFileName);
    end;
  end else begin
    Redirection := GlobalLodRedirs[OldFileName];
  
    if Redirection = nil then begin
      GlobalLodRedirs[OldFileName] := TString.Create(NewFileName);
    end else begin
      Redirection.Value := NewFileName;
    end;
  end; // .else
  
  {!} Windows.LeaveCriticalSection(RedirCritSection);
end; // .procedure GlobalRedirectFile

procedure OnBeforeErmInstructions (Event: PEvent); stdcall;
begin
  LodRedirs.Clear;
end;

procedure OnSavegameWrite (Event: PEvent); stdcall;
begin
  with Stores.NewRider(LODREDIR_SAVE_SECTION) do begin
    WriteInt(LodRedirs.ItemCount);

    with DataLib.IterateDict(LodRedirs) do begin
      while IterNext do begin
        WriteStr(IterKey);
        WriteStr(TString(IterValue).Value);
      end;
    end;
  end;
end; // .procedure OnSavegameWrite

procedure OnSavegameRead (Event: PEvent); stdcall;
var
  NumRedirs:    integer;
  OldFileName:  string;
  NewFileName:  string;
  i:            integer;

begin
  {!} Windows.EnterCriticalSection(RedirCritSection);
  LodRedirs.Clear;

  with Stores.NewRider(LODREDIR_SAVE_SECTION) do begin
    NumRedirs := ReadInt;

    for i := 0 to NumRedirs - 1 do begin
      OldFileName            := ReadStr;
      NewFileName            := ReadStr;
      LodRedirs[OldFileName] := TString.Create(NewFileName);
    end;
  end; 

  {!} Windows.LeaveCriticalSection(RedirCritSection);
end; // .procedure OnSavegameRead

procedure OnBeforeWoG (Event: PEvent); stdcall;
begin
  (* Remove WoG h3custom and h3wog lods registration *)
  PWORD($7015E5)^ :=  $38EB;
  Core.Hook(@Hook_LoadLods, Core.HOOKTYPE_BRIDGE, 5, Ptr($559408));
  
  (* Lods files redirection mechanism *)
  Core.ApiHook(@Hook_FindFileInLod, Core.HOOKTYPE_BRIDGE, Ptr($4FB106));
  Core.ApiHook(@Hook_FindFileInLod, Core.HOOKTYPE_BRIDGE, Ptr($4FACA6)); // A0_Lod_FindResource_sub_4FACA0
end;

procedure OnAfterWoG (Event: PEvent); stdcall;
begin
  LoadGlobalRedirectionConfig(GLOBAL_REDIRECTIONS_CONFIG_DIR, REDIRECT_MISSING_AND_EXISTING);
end;

begin
  Windows.InitializeCriticalSection(RedirCritSection);
  GlobalLodRedirs := AssocArrays.NewStrictAssocArr(TString);
  LodRedirs       := AssocArrays.NewStrictAssocArr(TString);
  LodList         := Lists.NewSimpleStrList;

  EventMan.GetInstance.On('OnBeforeWoG',             OnBeforeWoG);
  EventMan.GetInstance.On('OnAfterWoG',              OnAfterWoG);
  EventMan.GetInstance.On('OnBeforeErmInstructions', OnBeforeErmInstructions);
  EventMan.GetInstance.On('OnSavegameWrite',         OnSavegameWrite);
  EventMan.GetInstance.On('OnSavegameRead',          OnSavegameRead);
end.
