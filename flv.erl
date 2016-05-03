-module(flv).
-export([test/0, load_demo/0, eat_header/1, eat_previous_tag_size/1, eat_tag/1]).

test() ->
    Bin = load_demo(),
    {Header, Body} = eat_header(Bin),
    io:format("~p~n", [{header, Header}]),
    test_tag_loop(Body).

test_tag_loop(Bin) ->
    {PreviousTagSize, Rest} = eat_previous_tag_size(Bin),
    io:format("~p~n", [{previous_tag_size, PreviousTagSize}]),
    case byte_size(Rest) of
        RestLen when RestLen > 0 ->
            {Tag, Rest2} = eat_tag(Rest),
            io:format("~p~n", [tag_trans(Tag)]),
            test_tag_loop(Rest2);
        _ ->
            ok
    end.

tag_trans(Tag) ->
    case Tag of
        {video_tag, F1, F2, F3, F4, F5, F6, F7, F8, {data, Data}} ->
            {video_tag, F1, F2, F3, F4, F5, F6, F7, F8, {data, <<>>}};
        _ ->
            Tag
    end.

load_demo() ->
    {ok, Bin} = file:read_file("demo.flv"),
    Bin.

eat_header(Bin) ->
    {<<"FLV", 
       1, 
       TypeFlagsReserved1:5/bits, 
       TypeFlagsAudio:1/bits, 
       TypeFlagsReserved2:1/bits, 
       TypeFlagsVideo:1/bits, 
       DataOffset:4/binary>>, 
     Body} = split_binary(Bin, 9),
    {{{signature, <<"FLV">>}, 
      {version, <<1>>}, 
      {type_flags_reserved, TypeFlagsReserved1}, 
      {type_flags_audio, TypeFlagsAudio}, 
      {type_flags_reserved, TypeFlagsReserved2}, 
      {type_flags_video, TypeFlagsVideo}, {data_offset, DataOffset}},
      Body
    }.

eat_previous_tag_size(Bin) ->
    {PreviousTagSize, Rest} = split_binary(Bin, 4).

eat_tag(TagBeginBin) ->
    % 接下来的长度是变化的，因为这个块可能是 Audio、Video、Script 三者中的某一种
    % 而且还要考虑 Encryption 问题
    % 但不管是哪一种，都有一个公用的前缀部分，我们先解析这个部分
    {<<Reserved:2/bits, 
       Filter:1/bits, 
       TagType:5/bits, 
       DataSize:3/binary, 
       Timestamp:3/binary, 
       TimestampExtended:1/binary, 
       StreamID:3/binary>>, 
     Rest2} = split_binary(TagBeginBin, 1+3+3+1+3),
    % 目前不支持加密类型的 tag 因此 Filter 不能为 1
    <<0:1>> = Filter,

    % DataSize 从二进制形态转为整数形态
    % 注意 DataSize 实际上是从 StreamID 之后开始的第一个字节，到整个数据部分结束的总长度
    % 因此 AudioTagHeader 等都是要计入 DataSize 内的
    DataSizeUInt = binary:decode_unsigned(DataSize, big),

    % 接下来根据 TagType 我们进行不同的处理：
    % 如果是 Audio 则需要解析 AudioTagHeader
    % 如果是 Video 则需要解析 VideoTagHeader
    % 如果是 Script Data 则不需要解析什么
    case TagType of
        % Audio
        <<8:5>> ->
            {AudioTagHeader, AudioTagHeaderLen, Rest3} = eat_audio_tag_header(Rest2),
            {Data, Rest4} = split_binary(Rest3, DataSizeUInt - AudioTagHeaderLen),
            {{audio_tag, {reserved, Reserved}, 
                         {filter, Filter}, 
                         {tag_type, TagType}, 
                         {data_size, DataSize}, 
                         {timestamp, Timestamp}, 
                         {timestamp_ex, TimestampExtended}, 
                         {stream_id, StreamID},
                         {audio_tag_header, AudioTagHeader},
                         {data, Data}},
             Rest4};
        % Video
        <<9:5>> ->
            {VideoTagHeader, VideoTagHeaderLen, Rest3} = eat_video_tag_header(Rest2),
            % io:format("split_binary: ~p ~p~n", [byte_size(Rest3), DataSizeUInt - VideoTagHeaderLen]),
            {Data, Rest4} = split_binary(Rest3, DataSizeUInt - VideoTagHeaderLen),
            {{video_tag, {reserved, Reserved}, 
                         {filter, Filter}, 
                         {tag_type, TagType}, 
                         {data_size, DataSize}, 
                         {timestamp, Timestamp}, 
                         {timestamp_ex, TimestampExtended}, 
                         {stream_id, StreamID},
                         {video_tag_header, VideoTagHeader},
                         {data, Data}},
             Rest4};
        % Script Data
        <<18:5>> ->
            {Data, Rest3} = split_binary(Rest2, DataSizeUInt),
            {{script_data_tag, {reserved, Reserved}, 
                               {filter, Filter}, 
                               {tag_type, TagType}, 
                               {data_size, DataSize}, 
                               {timestamp, Timestamp}, 
                               {timestamp_ex, TimestampExtended}, 
                               {stream_id, StreamID},
                               {data, Data}},
             Rest3};
        % Unknown
        _ ->
            unknown
    end.

eat_audio_tag_header(Bin) ->
    {<<SoundFormat:4/bits, SoundRate:2/bits, SoundSize:1/bits, SoundType:1/bits>>, Rest} = split_binary(Bin, 1),
    % 如果 SoundFormat 为 10 的话，需要额外解析 AACPacketType
    case SoundFormat of
        <<10:4>> ->
            {<<AACPacketType:1/binary>>, Rest2} = split_binary(Rest, 1),
            {{{sound_format, SoundFormat}, 
              {sound_rate, SoundRate}, 
              {sound_size, SoundSize}, 
              {sound_type, SoundType}, 
              {aac_packet_type, AACPacketType}},
             1+1,
             Rest2};
        _ ->
            {{{sound_format, SoundFormat},
              {sound_rate, SoundRate},
              {sound_size, SoundSize},
              {sound_type, SoundType}},
             1,
             Rest}
    end.

eat_video_tag_header(Bin) ->
    {<<FrameType:4/bits, CodecID:4/bits>>, Rest} = split_binary(Bin, 1),
    % 如果 CodecID 为 7 的话，需要额外解析 AVCPacketType 和 CompositionTime
    case CodecID of
        <<7:4>> ->
            {<<AVCPacketType:1/binary, CompositionTime:3/binary>>, Rest2} = split_binary(Rest, 4),
            {{{frame_type, FrameType},
              {codec_id, CodecID},
              {avc_packet_type, AVCPacketType},
              {composition_time, CompositionTime}},
             1+4,
             Rest2};
        _ ->
            {{{frame_type, FrameType}, 
              {codec_id, CodecID}}, 
             1, 
             Rest}
    end.
