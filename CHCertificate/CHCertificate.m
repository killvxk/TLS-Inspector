//
//  CHCertificate.m
//
//  MIT License
//
//  Copyright (c) 2016 Ian Spence
//  https://github.com/ecnepsnai/CHCertificate
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

#import "CHCertificate.h"

#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <CommonCrypto/CommonCrypto.h>

@interface CHCertificate()

@property (nonatomic) X509 * certificate;
@property (strong, nonatomic, readwrite) NSString * summary;
@property (strong, nonatomic) NSArray<NSString *> * subjectAltNames;

@end

@implementation CHCertificate

static const int CERTIFICATE_SUBJECT_MAX_LENGTH = 150;

- (void) openSSLError {
    const char * file;
    int line;
    ERR_peek_last_error_line(&file, &line);
    NSLog(@"OpenSSL error in file: %s:%i", file, line);
}

+ (CHCertificate *) fromX509:(void *)cert {
    CHCertificate * xcert = [CHCertificate new];
    xcert.certificate = (X509 *)cert;
    xcert.summary = [xcert generateSummary];
    return xcert;
}

- (NSString *) getSubjectNID:(int)nid {
    X509_NAME * name = X509_get_subject_name(self.certificate);
    char * value = malloc(CERTIFICATE_SUBJECT_MAX_LENGTH);
    int length = X509_NAME_get_text_by_NID(name, nid, value, CERTIFICATE_SUBJECT_MAX_LENGTH);
    NSString * subject = [[NSString alloc] initWithBytes:value length:length encoding:NSUTF8StringEncoding];
    free(value);
    return subject;
}

- (NSString *) generateSummary {
    return [self getSubjectNID:NID_commonName];
}

- (NSString *) SHA512Fingerprint {
    return [self digestOfType:CHCertificateFingerprintTypeSHA512];
}

- (NSString *) SHA256Fingerprint {
    return [self digestOfType:CHCertificateFingerprintTypeSHA256];
}

- (NSString *) MD5Fingerprint {
    return [self digestOfType:CHCertificateFingerprintTypeMD5];
}

- (NSString *) SHA1Fingerprint {
    return [self digestOfType:CHCertificateFingerprintTypeSHA1];
}

- (NSString *) digestOfType:(CHCertificateFingerprintType)type {
    const EVP_MD * digest;

    switch (type) {
        case CHCertificateFingerprintTypeSHA512:
            digest = EVP_sha512();
            break;
        case CHCertificateFingerprintTypeSHA256:
            digest = EVP_sha256();
            break;
        case CHCertificateFingerprintTypeSHA1:
            digest = EVP_sha1();
            break;
        case CHCertificateFingerprintTypeMD5:
            digest = EVP_md5();
            break;
    }

    unsigned char fingerprint[EVP_MAX_MD_SIZE];

    unsigned int fingerprint_size = sizeof(fingerprint);
    if (X509_digest(self.certificate, digest, fingerprint, &fingerprint_size) < 0) {
        NSLog(@"Unable to generate certificate fingerprint");
        return @"";
    }

    NSMutableString * fingerprintString = [NSMutableString new];

    for (int i = 0; i < fingerprint_size && i < EVP_MAX_MD_SIZE; i++) {
        [fingerprintString appendFormat:@"%02x", fingerprint[i]];
    }

    return fingerprintString;
}

- (BOOL) verifyFingerprint:(NSString *)fingerprint type:(CHCertificateFingerprintType)type {
    NSString * actualFingerprint = [self digestOfType:type];
    NSString * formattedFingerprint = [[fingerprint componentsSeparatedByCharactersInSet:[[NSCharacterSet
                                                                                           alphanumericCharacterSet]
                                                                                          invertedSet]]
                                       componentsJoinedByString:@""];

    return [[actualFingerprint lowercaseString] isEqualToString:[formattedFingerprint lowercaseString]];
}

- (NSString *) serialNumber {
    NSMutableString * s = [NSMutableString new];
    int length = (int)self.certificate->cert_info->serialNumber->length;
    for (int i = 0; i < length; i++) {
        unsigned char data = (unsigned char)self.certificate->cert_info->serialNumber->data[i];
        [s appendString:[NSString stringWithFormat:@"%02x", data]];
    }
    return s;
}

- (NSString *) algorithm {
    X509_ALGOR * sig_type = self.certificate->sig_alg;
    char buffer[128];
    OBJ_obj2txt(buffer, sizeof(buffer), sig_type->algorithm, 0);
    return [NSString stringWithUTF8String:buffer];
}

- (NSDate *) notAfter {
    return [self dateFromASNTIME:X509_get_notAfter(self.certificate)];
}

- (NSDate *) notBefore {
    return [self dateFromASNTIME:X509_get_notBefore(self.certificate)];
}

- (NSDate *) dateFromASNTIME:(ASN1_TIME *)time {
    // Source: http://stackoverflow.com/a/8903088/1112669
    ASN1_GENERALIZEDTIME *certificateExpiryASN1Generalized = ASN1_TIME_to_generalizedtime(time,
                                                                                          NULL);
    if (certificateExpiryASN1Generalized != NULL) {
        unsigned char *certificateExpiryData = ASN1_STRING_data(certificateExpiryASN1Generalized);

        // ASN1 generalized times look like this: "20131114230046Z"
        //                                format:  YYYYMMDDHHMMSS
        //                               indices:  01234567890123
        //                                                   1111
        // There are other formats (e.g. specifying partial seconds or
        // time zones) but this is good enough for our purposes since
        // we only use the date and not the time.
        //
        // (Source: http://www.obj-sys.com/asn1tutorial/node14.html)

        NSString *expiryTimeStr = [NSString stringWithUTF8String:(char *)certificateExpiryData];
        NSDateComponents *expiryDateComponents = [[NSDateComponents alloc] init];

        expiryDateComponents.year   = [[expiryTimeStr substringWithRange:NSMakeRange(0, 4)]
                                       intValue];
        expiryDateComponents.month  = [[expiryTimeStr substringWithRange:NSMakeRange(4, 2)]
                                       intValue];
        expiryDateComponents.day    = [[expiryTimeStr substringWithRange:NSMakeRange(6, 2)]
                                       intValue];
        expiryDateComponents.hour   = [[expiryTimeStr substringWithRange:NSMakeRange(8, 2)]
                                       intValue];
        expiryDateComponents.minute = [[expiryTimeStr substringWithRange:NSMakeRange(10, 2)]
                                       intValue];
        expiryDateComponents.second = [[expiryTimeStr substringWithRange:NSMakeRange(12, 2)]
                                       intValue];

        NSCalendar *calendar = [NSCalendar currentCalendar];
        return [calendar dateFromComponents:expiryDateComponents];
    }
    return nil;
}

- (BOOL) validIssueDate {
    BOOL valid = YES;
    if ([self.notBefore timeIntervalSinceNow] > 0) {
        valid = NO;
    }
    if ([self.notAfter timeIntervalSinceNow] < 0) {
        valid = NO;
    }
    return valid;
}

- (NSString *) issuer {
    X509_NAME *issuerX509Name = X509_get_issuer_name(self.certificate);

    if (issuerX509Name != NULL) {
        int index = X509_NAME_get_index_by_NID(issuerX509Name, NID_organizationName, -1);
        X509_NAME_ENTRY *issuerNameEntry = X509_NAME_get_entry(issuerX509Name, index);

        if (issuerNameEntry) {
            ASN1_STRING *issuerNameASN1 = X509_NAME_ENTRY_get_data(issuerNameEntry);

            if (issuerNameASN1 != NULL) {
                unsigned char *issuerName = ASN1_STRING_data(issuerNameASN1);
                return [NSString stringWithUTF8String:(char *)issuerName];
            }
        }
    }
    return @"";
}

- (NSDictionary<NSString *, NSString *> *) names {
#define add_subject(k, nid) value = [self getSubjectNID:nid]; if (value != nil) { [names setObject:value forKey:k]; }

    NSMutableDictionary<NSString *, NSString *> * names = [NSMutableDictionary new];
    NSString * value;

    add_subject(@"CN", NID_commonName);
    add_subject(@"C", NID_countryName);
    add_subject(@"S", NID_stateOrProvinceName);
    add_subject(@"L", NID_localityName);
    add_subject(@"O", NID_organizationName);
    add_subject(@"OU", NID_organizationalUnitName);
    add_subject(@"E", NID_pkcs9_emailAddress);

    return names;
}

- (void *) X509Certificate {
    return self.certificate;
}

- (NSData *) publicKeyAsPEM {
    BIO * buffer = BIO_new(BIO_s_mem());
    if (PEM_write_bio_X509(buffer, self.certificate)) {
        BUF_MEM *buffer_pointer;
        BIO_get_mem_ptr(buffer, &buffer_pointer);
        char * pem_bytes = malloc(buffer_pointer->length);
        memcpy(pem_bytes, buffer_pointer->data, buffer_pointer->length-1);

        // Exclude the null terminator from the NSData object
        NSData * pem = [NSData dataWithBytes:pem_bytes length:buffer_pointer->length -1];

        free(pem_bytes);
        free(buffer);

        return pem;
    }

    free(buffer);
    return nil;
}

- (NSArray<NSString *> *) subjectAlternativeNames {
    // This will leak
    STACK_OF(GENERAL_NAME) * sans = X509_get_ext_d2i(self.certificate, NID_subject_alt_name, NULL, NULL);
    int numberOfSans = sk_GENERAL_NAME_num(sans);
    if (numberOfSans < 1) {
        return @[];
    }

    if (self.subjectAltNames) {
        return self.subjectAltNames;
    }

    NSMutableArray<NSString *> * names = [NSMutableArray new];
    const GENERAL_NAME * name;
    char * domain;
    for (int i = 0; i < numberOfSans; i++) {
        name = sk_GENERAL_NAME_value(sans, i);

        if (name->type == GEN_DNS) {
            domain = (char *)ASN1_STRING_data(name->d.dNSName);
            [names addObject:[NSString stringWithUTF8String:domain]];
        }
    }

    self.subjectAltNames = names;
    free(sans);

    return names;
}

@end
