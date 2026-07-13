FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

WORKDIR /src
COPY . .

RUN dotnet restore \
    HappyFinger/HappyFinger.csproj

RUN dotnet publish \
    HappyFinger/HappyFinger.csproj \
    --configuration Release \
    --output /app/publish \
    --no-restore \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/runtime:10.0

WORKDIR /app
COPY --from=build /app/publish .

EXPOSE 79

ENTRYPOINT ["dotnet", "HappyFinger.dll"]
